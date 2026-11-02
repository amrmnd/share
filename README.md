# PaddleOCR-VL on Kubernetes (vLLM + 공식 파이프라인 API)

PaddleOCR-VL-0.9B를 vLLM으로 서빙하고, PaddleOCR 공식 `paddleocr-vl` 이미지로 문서 파싱 API를 띄우는 구성입니다.

```
클라이언트 ──POST /layout-parsing──▶ Ingress / Service: paddleocr-api
                                        │
                                        ▼
                       paddleocr-api Pod × N (공식 paddleocr-vl 이미지)
                         1) PP-DocLayoutV2 레이아웃 검출 + 읽기 순서
                         2) 영역별 crop ──HTTP /v1──▶ Service: vllm-paddleocr-vl
                                                         vLLM (PaddleOCR-VL-0.9B, GPU)
                         3) 페이지별 Markdown / JSON 조립 후 응답
```

## 파일 구성

| 파일 | 리소스 | 역할 |
|---|---|---|
| `k8s/01-vllm-paddleocr-vl.yaml` | Namespace, Deployment, Service | `paddleocr` 네임스페이스 생성, vLLM으로 VLM 서빙 (OpenAI 호환 API, 포트 8000) |
| `k8s/02-pipeline-api.yaml` | ConfigMap, Deployment, Service, PDB, HPA, Ingress | 공식 이미지로 파이프라인 API 실행, VL 인식은 01번의 vLLM으로 위임 |

### 01-vllm-paddleocr-vl.yaml

vLLM 레시피 문서의 서빙 명령을 그대로 옮겼습니다.

```
vllm serve PaddlePaddle/PaddleOCR-VL --trust-remote-code \
  --max-num-batched-tokens 16384 --no-enable-prefix-caching --mm-processor-cache-gb 0
```

- `--served-model-name PaddleOCR-VL-0.9B PaddlePaddle/PaddleOCR-VL`: 파이프라인이 `PaddleOCR-VL-0.9B` 이름으로 요청하므로, 두 이름을 모두 등록해 `The model ... does not exist` 오류를 방지합니다.
- `--no-enable-prefix-caching`, `--mm-processor-cache-gb=0`: OCR 요청은 캐시 재사용 이득이 거의 없으므로 끕니다.
- `--max-num-batched-tokens`: 처리량에 가장 큰 영향을 주는 값입니다. GPU 성능에 맞게 조정하세요.
- 모델 캐시는 `emptyDir`(20Gi)에 저장합니다. Pod가 재시작되면 Hugging Face에서 다시 다운로드합니다. startupProbe는 최대 15분까지 기다립니다.
- 클러스터 내부 주소는 `http://vllm-paddleocr-vl.paddleocr.svc.cluster.local:8000/v1` 입니다.

### 02-pipeline-api.yaml

PaddleOCR 공식 `paddleocr-vl` 이미지를 `paddlex --serve`로 실행합니다.

**설정 생성 방식**
1. initContainer `gen-config`가 같은 이미지에서 `paddlex --get_pipeline_config PaddleOCR-VL`로 기본 설정을 만듭니다.
2. `patch_config.py`가 아래 항목만 덮어씁니다. 나머지는 이미지가 생성한 그대로 두므로 설정 키가 항상 이미지 버전과 일치합니다.
   - `VLRecognition.genai_config`: `backend: vllm-server`, `server_url`, `max_concurrency`, `api_model_name`
   - `LayoutDetection.model_name`: `PP-DocLayoutV2` (필요 시 `model_dir`)
3. 메인 컨테이너가 패치된 `/config/PaddleOCR-VL.yaml`로 서버를 시작합니다 (포트 8080).

**ConfigMap 값**

| 키 | 기본값 | 설명 |
|---|---|---|
| `VLLM_SERVER_URL` | `http://vllm-paddleocr-vl.paddleocr.svc.cluster.local:8000/v1` | vLLM 주소 |
| `VLM_API_MODEL_NAME` | `PaddleOCR-VL-0.9B` | vLLM에 요청할 모델명. 01번의 `--served-model-name` 중 하나여야 함 |
| `VLM_MAX_CONCURRENCY` | `8` | Pod 하나가 vLLM에 동시에 보내는 crop 요청 수 |
| `LAYOUT_MODEL_NAME` | `PP-DocLayoutV2` | 레이아웃 모델. 비우면 이미지 기본값 사용 |
| `LAYOUT_MODEL_DIR` | (빈 값) | 직접 받은 가중치를 쓸 때만 지정. 볼륨 마운트도 함께 추가해야 함 |

**운영 관련 설정**
- readinessProbe는 API의 `/health`와 vLLM의 `/health`가 모두 정상일 때만 통과합니다. vLLM이 재시작 중이면 API Pod도 트래픽에서 빠집니다.
- 공식 표준 서빙은 Pod당 요청을 한 번에 하나씩 처리합니다. 동시 요청은 replicas와 HPA(2~6, CPU 70%)로 소화합니다.
- PDB(`minAvailable: 1`)와 `preStop` + `terminationGracePeriodSeconds: 120`으로 무중단 롤링 업데이트를 지원합니다.
- 파일을 Base64 JSON으로 보내면 원본보다 약 33% 커지므로, Ingress 업로드 한도를 70MB로, 타임아웃을 600초로 늘렸습니다.

## 사전 준비

- Kubernetes 클러스터에 NVIDIA GPU 노드와 NVIDIA device plugin이 설치되어 있어야 합니다. 리소스명은 `nvidia.com/gpu`입니다.
- 노드의 NVIDIA 드라이버가 CUDA 12.6 이상을 지원해야 합니다.
- GPU 수: vLLM 1개 + API Pod당 1개가 필요합니다. 기본 구성(API 2개) 기준 최소 3개입니다.
- HPA를 쓰려면 metrics-server가 있어야 합니다.
- Ingress를 쓰려면 ingress-nginx가 있어야 합니다.

## 배포 전 수정할 항목

| 파일 | 항목 | 내용 |
|---|---|---|
| 02 | `image` (initContainer와 main이 앵커 `&image`로 공유) | 플레이스홀더 태그 `paddleocr3.3-nvidia-gpu-offline`을 실제 사용할 고정 태그로 변경. 사내 레지스트리 미러 주소 권장 |
| 02 | Ingress `host` | `ocr.example.com`을 실제 도메인으로 변경. 외부 노출이 필요 없으면 Ingress 리소스 삭제 |
| 01 | `image` | `vllm/vllm-openai:v0.11.1`. PaddleOCR-VL은 v0.11.1 이상이 필요하며, 운영에서는 검증된 버전으로 고정 |
| 01 | `--max-num-batched-tokens`, `--gpu-memory-utilization` | GPU에 맞게 조정 |
| 01, 02 | `nodeSelector` / `tolerations` | GPU 노드에 taint가 있으면 01번의 주석을 해제해 값을 수정하고, 02번 Pod spec에도 같은 내용을 추가 |

### 이미지 미러링 (권장)

공식 이미지 레지스트리는 중국 베이징에 있어 국내에서 pull이 느리거나, 폐쇄망에서는 접근할 수 없습니다. 사내 레지스트리로 옮겨두세요. `-offline` 태그는 모델이 이미지에 포함되어 있어 폐쇄망에서도 동작합니다.

```bash
SRC=ccr-2vdh3abv-pub.cnc.bj.baidubce.com/paddlepaddle/paddleocr-vl:<태그>
DST=registry.example.com/paddlepaddle/paddleocr-vl:<태그>
docker pull $SRC && docker tag $SRC $DST && docker push $DST
```

## 배포 절차

### 1. (선택) Hugging Face 토큰

vLLM이 모델을 받을 때 사용합니다. 공개 모델이라 없어도 동작하지만, 다운로드 속도 제한을 피하려면 등록하세요. 네임스페이스는 01번에서 만들어지므로 먼저 생성합니다.

```bash
kubectl create namespace paddleocr
kubectl -n paddleocr create secret generic hf-token --from-literal=token=hf_xxx
```

### 2. vLLM 배포

```bash
kubectl apply -f k8s/01-vllm-paddleocr-vl.yaml
kubectl -n paddleocr rollout status deploy/vllm-paddleocr-vl --timeout=20m
```

동작 확인:

```bash
kubectl -n paddleocr port-forward svc/vllm-paddleocr-vl 8000:8000
curl -s localhost:8000/v1/models | jq '.data[].id'
# "PaddleOCR-VL-0.9B", "PaddlePaddle/PaddleOCR-VL" 두 이름이 보여야 함
```

### 3. 파이프라인 API 배포

```bash
kubectl apply -f k8s/02-pipeline-api.yaml
kubectl -n paddleocr rollout status deploy/paddleocr-api --timeout=15m
```

### 4. 패치된 설정 확인 (최초 배포 시 필수)

```bash
kubectl -n paddleocr logs deploy/paddleocr-api -c gen-config
```

출력에서 아래 항목을 확인합니다.
- `VLRecognition.genai_config.server_url`이 vLLM 주소인지
- `VLRecognition`의 모델이 vLLM이 서빙하는 모델(PaddleOCR-VL v1, `PaddleOCR-VL-0.9B`)과 같은 버전인지
- `LayoutDetection.model_name`이 `PP-DocLayoutV2`인지

### 5. API 호출 테스트

```bash
kubectl -n paddleocr port-forward svc/paddleocr-api 8080:80

# 이미지 URL
curl -s localhost:8080/layout-parsing -H 'Content-Type: application/json' \
  -d '{"file":"https://paddle-model-ecology.bj.bcebos.com/paddlex/imgs/demo_image/paddleocr_vl_demo.png","fileType":1}' \
  | jq '.errorCode, .errorMsg'

# 로컬 PDF (Base64)
jq -n --arg f "$(base64 -w0 sample.pdf)" '{file:$f, fileType:0}' \
  | curl -s localhost:8080/layout-parsing -H 'Content-Type: application/json' -d @- \
  | jq '.result | keys'
```

`errorCode: 0`, `errorMsg: "Success"`가 나오면 정상입니다.

## API 요약

`POST /layout-parsing` (JSON)

| 필드 | 필수 | 설명 |
|---|---|---|
| `file` | O | 이미지/PDF의 URL 또는 Base64 문자열 |
| `fileType` | | `0` = PDF, `1` = 이미지 |

응답은 `{ logId, errorCode, errorMsg, result }` 형식입니다. 전체 필드는 [PaddleOCR-VL 공식 문서](https://www.paddleocr.ai/latest/en/version3.x/pipeline_usage/PaddleOCR-VL.html)의 서비스 배포 섹션을 참고하세요.

## 문제 해결

| 증상 | 원인 / 조치 |
|---|---|
| `The model ... does not exist` | 파이프라인이 요청한 모델명이 vLLM에 없음. `gen-config` 로그에서 요청 모델명을 확인하고 01번 `--served-model-name`에 추가하거나, `VLM_API_MODEL_NAME`을 맞춤 |
| 인식 결과가 깨지거나 형식이 이상함 | 이미지의 파이프라인 버전과 vLLM 모델 버전이 다름 (예: 파이프라인은 PaddleOCR-VL-1.5 기준, vLLM은 v1). 이미지 태그를 v1 기준으로 고정하거나 vLLM 모델을 같은 버전으로 올림 |
| `gen-config`가 `VLRecognition section not found`로 실패 | 이미지 버전에 따라 설정 구조가 다름. 생성된 설정을 확인하고 `patch_config.py`의 섹션 이름을 수정 |
| API Pod가 Ready가 되지 않음 | readinessProbe가 vLLM `/health`도 확인함. `kubectl -n paddleocr get pods`로 vLLM 상태부터 확인 |
| vLLM 기동이 15분 이상 걸림 | 모델 다운로드가 느림. HF 토큰 등록, `HF_ENDPOINT`로 미러 사용, 또는 `hf-cache`를 PVC로 교체 |
| 업로드 시 413 | Ingress `proxy-body-size` 상향 |
| 요청이 많을 때 지연 | API는 Pod당 1요청씩 처리. HPA `maxReplicas` 상향, vLLM `--max-num-batched-tokens` 및 replicas 조정 |

## 삭제

```bash
kubectl delete -f k8s/02-pipeline-api.yaml
kubectl delete -f k8s/01-vllm-paddleocr-vl.yaml   # 네임스페이스까지 삭제됨
```
