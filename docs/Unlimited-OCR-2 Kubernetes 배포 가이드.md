# Unlimited-OCR-2 Kubernetes 배포 가이드

Nov 3, 2026 · @Amarmend

## 개요

Unlimited-OCR-2는 Baidu 커스텀 SGLang 빌드로 GPU 1장당 Pod 1개를 띄워 서빙하는 것이 기본 구성입니다. 공식 문서가 서빙용으로 SGLang만 권장하고, 일반 SGLang/vLLM 이미지로는 v2의 SR-SWA 경로가 동작하지 않기 때문입니다.

| 항목 | 내용 |
| --- | --- |
| 모델 | [baidu/Unlimited-OCR-2](https://huggingface.co/baidu/Unlimited-OCR-2), 3B 파라미터, BF16, MIT 라이선스 (2026-10-27 공개) |
| 핵심 구조 | SR-SWA(Sparse Reference Sliding Window Attention): 문서가 길어져도 디코딩 단계당 지연·메모리가 거의 일정 |
| 입력 | 페이지 이미지 N장을 한 요청으로 전달(PDF는 클라이언트에서 이미지로 변환) |
| 서빙 엔진 | 커스텀 SGLang wheel `sglang-0.5.20.dev13+g75b9b06b02` (OpenAI 호환 `/v1/chat/completions`) |
| 공식 검증 환경 | Python 3.10, torch 2.13.0, NVIDIA A800-80GB |
| 미지원 | vLLM(v2 미지원), 양자화 가중치(커스텀 SGLang은 BF16만 로드) |

배포 구성은 다음 다섯 가지 리소스로 이뤄집니다.

1. 커스텀 SGLang wheel을 넣은 서빙 이미지
2. 모델 가중치를 담는 PVC와 이를 채우는 다운로드 Job
3. 메모리·페이지 윈도우 환경변수를 담는 ConfigMap
4. GPU 1장을 요청하는 Deployment
5. 스트리밍 응답을 오래 유지하는 Service(+선택적 Ingress)

&#91;embedded content: 배포 아키텍처 · 요청 경로와 가중치 경로\]

요청은 Ingress와 Service를 거쳐 GPU Pod로 들어가고, Pod는 다운로드 Job이 채운 PVC를 읽기 전용으로, ConfigMap을 환경변수로 받습니다.

## 사전 요구사항

GPU 노드, NVIDIA 디바이스 플러그인, 가중치용 스토리지 세 가지가 준비돼 있어야 합니다.

| 항목 | 요구사항 | 확인 명령 |
| --- | --- | --- |
| GPU 노드 | NVIDIA GPU, 공식 검증은 A800-80GB. 80GB급(A100/H100)에서 기본 튜닝값(`--max-running-requests 64`) 그대로 사용 가능 | `kubectl get nodes -L nvidia.com/gpu.product` |
| GPU Operator / 디바이스 플러그인 | `nvidia.com/gpu` 리소스가 노드에 노출돼 있을 것 | `kubectl describe node <node> \| grep nvidia.com/gpu` |
| 드라이버 | CUDA 13.0 이상을 지원하는 드라이버 (현재 노드: nvidia-smi 기준 CUDA 13.0 → 이미지·torch 모두 cu130) | `nvidia-smi` |
| 스토리지 | 가중치 + HF 캐시용 PVC 30Gi 이상. 레플리카를 여러 노드에 두면 RWX(NFS, CephFS 등) | `kubectl get sc` |
| 공유 메모리 | Pod에 `/dev/shm` 16\~32Gi (텐서 전달에 `/dev/shm` 사용) | 매니페스트에서 `emptyDir: medium: Memory` |
| 레지스트리 | 커스텀 이미지를 올릴 사내 레지스트리 | - |

폐쇄망이라면 이미지와 가중치를 외부에서 미리 받아 사내 레지스트리와 PVC(또는 오브젝트 스토리지)에 넣어 두고, 아래 다운로드 Job 대신 복사 Job을 사용합니다.

```bash
kubectl create namespace uocr
```

## 컨테이너 이미지 빌드

`lmsysorg/sglang:latest`는 쓰지 않습니다. Hugging Face 페이지의 Docker 예시는 자동 생성된 것이라 `--chat-template unlimited-ocr`와 `SGLANG_UOCR_*` 환경변수를 처리하는 커스텀 빌드가 빠져 있습니다. 대신 [GitHub 저장소](https://github.com/baidu/Unlimited-OCR)의 `wheel/` 디렉터리에 있는 커스텀 wheel로 이미지를 만듭니다.

```bash
git clone https://github.com/baidu/Unlimited-OCR.git
cd Unlimited-OCR
ls wheel/   # sglang-0.5.20.dev13+g75b9b06b02-py3-none-any.whl 확인
```

저장소 루트에 아래 Dockerfile을 둡니다. 공식 문서처럼 Python 3.10 + uv로 wheel을 의존성까지 설치합니다.

```
# 노드 드라이버가 CUDA 13.0까지 지원(nvidia-smi 기준) → torch 2.13 cu130 빌드에 맞춤
ARG CUDA_IMAGE=nvidia/cuda:13.0.0-cudnn-devel-ubuntu22.04
FROM ${CUDA_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \            
    UV_LINK_MODE=copy \
    VIRTUAL_ENV=/opt/venv \
    PATH=/opt/venv/bin:$PATH

RUN apt-get update && apt-get install -y --no-install-recommends \
      python3.10 python3.10-venv python3.10-dev curl ca-certificates libnuma1 git \
    && rm -rf /var/lib/apt/lists/*

RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
    && /root/.local/bin/uv venv --python 3.10 /opt/venv

# torch를 cu130 빌드로 먼저 고정 (wheel 설치 시 다른 CUDA 변형으로 덮이지 않도록)
RUN /root/.local/bin/uv pip install torch==2.13.0 torchvision \
      --index-url https://download.pytorch.org/whl/cu130

COPY wheel/sglang-0.5.20.dev13+g75b9b06b02-py3-none-any.whl /tmp/
RUN /root/.local/bin/uv pip install \
      /tmp/sglang-0.5.20.dev13+g75b9b06b02-py3-none-any.whl \
      pymupdf==1.27.2.2 fastokens==0.3.2 huggingface-hub==0.36.0 \
    && rm -f /tmp/*.whl

WORKDIR /app
EXPOSE 10000
ENTRYPOINT ["python", "-m", "sglang.launch_server"]
```

```bash
export IMG=registry.example.com/ai/unlimited-ocr2-sglang:0.5.20-uocr2
docker build -t $IMG .
docker push $IMG


     
# 로컬 GPU에서 import만 먼저 검증
docker run --rm --gpus all --entrypoint python $IMG -c "import sglang, torch; print(sglang.__version__, torch.__version__, torch.cuda.is_available())"
```

- 빌드 후 `torch.__version__`이 2.13.0인지, CUDA가 잡히는지 확인합니다. 다르면 `CUDA_IMAGE`를 바꿔 다시 빌드합니다.
- 이미지 태그에 wheel 버전을 넣어 두면 모델 업데이트 시 추적이 쉽습니다.

## 모델 가중치 준비

가중치는 Pod 기동 때마다 받지 않고 PVC에 한 번 받아 둔 뒤 읽기 전용으로 마운트합니다. 기동 시간이 줄고 레플리카를 늘려도 외부 다운로드가 반복되지 않습니다.

```yaml
# 01-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: uocr2-models
  namespace: uocr
spec:
  accessModes: ["ReadWriteMany"]   # 단일 노드면 ReadWriteOnce도 가능
  storageClassName: <your-rwx-sc>
  resources:
    requests:
      storage: 30Gi
---
# 02-download-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: uocr2-download
  namespace: uocr
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: download
          image: python:3.10-slim
          command: ["bash", "-c"]
          args:
            - |
              pip install -q huggingface-hub==0.36.0 && \
              huggingface-cli download baidu/Unlimited-OCR-2 \
                --local-dir /models/Unlimited-OCR-2
          env:
            - name: HF_TOKEN            # 공개 모델이므로 선택
              valueFrom:
                secretKeyRef: {name: hf-token, key: token, optional: true}
          volumeMounts:
            - {name: models, mountPath: /models}
      volumes:
        - name: models
          persistentVolumeClaim: {claimName: uocr2-models}
```

```bash
kubectl apply -f 01-pvc.yaml -f 02-download-job.yaml
kubectl -n uocr wait --for=condition=complete job/uocr2-download --timeout=30m
```

- 모델이 `trust_remote_code`를 쓰므로 `.py` 파일까지 통째로 받아야 합니다. `--local-dir` 전체 다운로드면 충족됩니다.
- 폐쇄망: 외부에서 같은 명령으로 받은 디렉터리를 tar로 묶어 반입하고, Job은 사내 오브젝트 스토리지(예: S3 호환)에서 `/models/Unlimited-OCR-2`로 복사하도록 바꿉니다.

## 배포 매니페스트

공식 README의 서버 기동 옵션을 그대로 옮기되, 모델 경로만 PVC로 바꿨습니다. 메모리 관련 환경변수는 ConfigMap으로 분리해 재빌드 없이 튜닝합니다.

### ConfigMap

```yaml
# 03-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: uocr2-env
  namespace: uocr
data:
  # 변수명의 EANABLE 오타는 공식 빌드 그대로이므로 고치지 말 것
  SGLANG_UOCR_EANABLE_DOC_LIMIT: "1"        # 1=페이지 윈도우 분할, 0=문서 전체를 한 윈도우로
  SGLANG_UOCR_DOC_GUNDAM_PAGE_WINDOW: "10"  # gundam(타일) 모드 윈도우당 페이지 수
  SGLANG_UOCR_DOC_BASE_PAGE_WINDOW: "10"    # base 모드 윈도우당 페이지 수
  SGLANG_UOCR_MAX_PAGE_TOKENS: "20000"      # 페이지당 출력 상한, 0보다 커야 함
  SGLANG_OPT_UOCR_SAM_REL_POS_BIAS_MB: "64" # 기본 512는 단일 대형 할당으로 OOM 가능
  SGLANG_UOCR_SHM_WRAP_MODEL_DATA: "1"      # 큰 텐서를 /dev/shm 경유로 전달
  SGLANG_UOCR_SHM_WRAP_MIN_MB: "1"
  SGLANG_VLM_CACHE_SIZE_MB: "0"
  PYTORCH_CUDA_ALLOC_CONF: "expandable_segments:True"
```

### Deployment

```yaml
# 04-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: uocr2
  namespace: uocr
  labels: {app: uocr2}
spec:
  replicas: 1
  strategy:
    type: Recreate            # GPU 1장 노드에서 롤링 시 신규 Pod Pending 방지
  selector:
    matchLabels: {app: uocr2}
  template:
    metadata:
      labels: {app: uocr2}
    spec:
      nodeSelector:
        nvidia.com/gpu.present: "true"
      tolerations:
        - {key: nvidia.com/gpu, operator: Exists, effect: NoSchedule}
      terminationGracePeriodSeconds: 120
      containers:
        - name: sglang
          image: registry.example.com/ai/unlimited-ocr2-sglang:0.5.20-uocr2
          args:
            - --model-path=/models/Unlimited-OCR-2
            - --served-model-name=Unlimited-OCR-2
            - --chat-template=unlimited-ocr
            - --tokenizer-backend=fastokens
            - --tokenizer-worker-num=8
            - --mem-fraction-static=0.7
            - --max-running-requests=64
            - --max-prefill-tokens=2048
            - --enable-custom-logit-processor
            - --enable-streaming-session
            - --allow-auto-truncate
            - --disable-radix-cache
            - --mm-preprocess-cache-size-mb=0
            - --cuda-graph-backend-decode=full
            - --cuda-graph-max-bs-decode=64
            - --cuda-graph-backend-prefill=full
            - --cuda-graph-max-bs-prefill=16384
            - --cuda-graph-bs-prefill
            - "1024"
            - "2048"
            - '--cuda-graph-config={"prefill": {"backend": "full", "full_prefill_max_req": 64}}'
            - --enable-metrics
            - --host=0.0.0.0
            - --port=10000
          envFrom:
            - configMapRef: {name: uocr2-env}
          env:
            - {name: HF_HUB_OFFLINE, value: "1"}   # PVC 가중치만 사용
          ports:
            - {name: http, containerPort: 10000}
          resources:
            requests: {cpu: "8", memory: 48Gi, nvidia.com/gpu: "1"}
            limits:   {cpu: "16", memory: 64Gi, nvidia.com/gpu: "1"}
          startupProbe:           # 가중치 로드 + CUDA graph 캡처에 수 분 소요
            httpGet: {path: /health, port: http}
            periodSeconds: 20
            failureThreshold: 60  # 최대 20분 대기
          readinessProbe:
            httpGet: {path: /health, port: http}
            periodSeconds: 10
            failureThreshold: 3
          livenessProbe:
            httpGet: {path: /health, port: http}
            periodSeconds: 30
            failureThreshold: 5
          volumeMounts:
            - {name: models, mountPath: /models, readOnly: true}
            - {name: dshm, mountPath: /dev/shm}
      volumes:
        - name: models
          persistentVolumeClaim: {claimName: uocr2-models, readOnly: true}
        - name: dshm
          emptyDir: {medium: Memory, sizeLimit: 32Gi}
```

### Service

```yaml
# 05-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: uocr2
  namespace: uocr
  labels: {app: uocr2}
spec:
  selector: {app: uocr2}
  ports:
    - {name: http, port: 10000, targetPort: http}
```

```bash
kubectl apply -f 03-configmap.yaml -f 04-deployment.yaml -f 05-service.yaml
kubectl -n uocr logs -f deploy/uocr2   # "The server is fired up" 로그까지 대기
```

- `/dev/shm`은 컨테이너 메모리 limit에 합산됩니다. `sizeLimit`을 늘리면 `limits.memory`도 함께 늘립니다.
- 클러스터 외부 노출 시 Ingress에서 응답 버퍼링을 끄고 타임아웃을 늘립니다. 수백 페이지 요청은 스트림이 수십 분 이어집니다 (공식 클라이언트 예제의 타임아웃이 6000초).

```yaml
# 06-ingress.yaml (ingress-nginx 기준, 선택)
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: uocr2
  namespace: uocr
  annotations:
    nginx.ingress.kubernetes.io/proxy-buffering: "off"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "6000"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "6000"
    nginx.ingress.kubernetes.io/proxy-body-size: "512m"   # base64 이미지 다수
spec:
  ingressClassName: nginx
  rules:
    - host: uocr.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: {name: uocr2, port: {name: http}}
```

## 동작 확인 및 API 호출

헬스체크와 모델 목록으로 기동을 확인한 뒤, 이미지 여러 장을 한 요청에 담아 `/v1/chat/completions`로 스트리밍 호출합니다.

```bash
kubectl -n uocr port-forward svc/uocr2 10000:10000 &
curl -s localhost:10000/health
curl -s localhost:10000/v1/models | jq .
```

요청 형식에서 지켜야 할 점은 다음과 같습니다.

- 프롬프트는 `"<PAGE><image>" * 페이지수 + "Multi page parsing."`이고, 이미지는 페이지 순서대로 넣습니다.
- `max_tokens`는 문서 전체 출력 예산이라 반드시 양수여야 합니다(예: 페이지당 8000 × 페이지수).
- `images_config.crop_mode`: `true`=gundam(타일, 정밀), `false`=base(페이지당 전역 뷰 1개, 가벼움).
- 반복 출력 억제용 n-gram 로짓 프로세서를 함께 보냅니다. 서버에 `--enable-custom-logit-processor`가 켜져 있어야 합니다.

```python
# client.py  (pip install requests pymupdf + 같은 커스텀 sglang wheel)
import base64, json, sys, fitz, requests
from sglang.srt.sampling.custom_logit_processor import DeepseekOCRNoRepeatNGramLogitProcessor

URL = "http://localhost:10000/v1/chat/completions"

def pdf_pages(path, dpi=300):
    doc = fitz.open(path)
    m = fitz.Matrix(dpi / 72, dpi / 72)
    return [p.get_pixmap(matrix=m).tobytes("png") for p in doc]

def ocr(pages, crop_mode=True, tokens_per_page=8000):
    content = [{"type": "image_url",
                "image_url": {"url": "data:image/png;base64," + base64.b64encode(b).decode()}}
               for b in pages]
    content.append({"type": "text", "text": "<PAGE><image>" * len(pages) + "Multi page parsing."})
    payload = {
        "model": "Unlimited-OCR-2",
        "messages": [{"role": "user", "content": content}],
        "max_tokens": tokens_per_page * len(pages),
        "temperature": 0,
        "skip_special_tokens": False,
        "images_config": {"crop_mode": crop_mode},
        "custom_logit_processor": DeepseekOCRNoRepeatNGramLogitProcessor.to_str(),
        "custom_params": {
            "ngram_size": 35,
            "window_size": 1024 if len(pages) > 1 else 128,
            "page_token_id": 128827,   # <PAGE> 토큰 id
            "eos_token_id": 1,
            "max_page_tokens": 20000,
        },
        "stream": True,
    }
    out = []
    with requests.post(URL, json=payload, stream=True, timeout=6000) as r:
        r.raise_for_status()
        for line in r.iter_lines(decode_unicode=True):
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            choices = json.loads(data).get("choices") or []
            if choices:
                out.append((choices[0].get("delta") or {}).get("content") or "")
    return "".join(out)

if __name__ == "__main__":
    print(ocr(pdf_pages(sys.argv[1])))
```

```bash
python client.py sample.pdf > sample.md
```

출력에는 입력 페이지마다 `<PAGE>` 구분자가 하나씩, 입력 순서대로 들어갑니다. 클라이언트에 커스텀 sglang을 설치하기 어렵다면 서버 Pod에서 `DeepseekOCRNoRepeatNGramLogitProcessor.to_str()` 결과 문자열을 한 번 출력해 상수로 박아 두고 쓰면 됩니다.

## 운영

메모리는 아래 네 옵션이 좌우하며, 공식 문서의 권장값(0.7 / 2048 / 버킷 최대=2048 / 64)이 32 동시 요청 이상에서도 안정적인 조합입니다.

### 메모리 튜닝

| 옵션 | 권장값 | 효과와 주의점 |
| --- | --- | --- |
| `--mem-fraction-static` | 0.7 | 가중치+KV 예약 비율. 0.75는 동시 32+ 요청에서 여유 부족 |
| `--max-prefill-tokens` | 2048 | 임시 텐서 크기가 이 값에 선형 비례. 4096→2048로 피크 절반 |
| `--cuda-graph-bs-prefill` | `1024 2048` | 최대 버킷은 반드시 `--max-prefill-tokens`와 같게. 작으면 eager 폴백, 크면 캡처 메모리 낭비 |
| `full_prefill_max_req` | 64 | 기본 8이면 16/32 동시 요청이 eager로 떨어짐 |
| 페이지 윈도우 (`*_PAGE_WINDOW`) | 10 | 줄이면 피크 메모리↓, 윈도우 경계에서 페이지 간 이어짐 품질↓ |

80GB 미만 GPU라면 `--max-running-requests`와 `--cuda-graph-max-bs-decode`를 함께 낮추고(예: 16), 페이지 윈도우를 줄이는 순서로 맞춰 봅니다. 이 값들은 공식 검증 밖이므로 실제 문서로 부하 테스트가 필요합니다.

### 스케일링

- 수평 확장: GPU 1장 = Pod 1개로 `replicas`를 늘립니다. 요청 하나가 수십 분 걸릴 수 있어 라운드로빈은 부하가 쏠립니다. 레플리카 앞에 SGLang Router(least-load)나 큐(Kafka/Redis + 워커)를 두는 편이 안정적입니다.
- 오토스케일: `--enable-metrics`로 노출되는 `/metrics`(실행/대기 요청 수)를 Prometheus Adapter나 KEDA로 받아 HPA 트리거로 씁니다. GPU 사용률(DCGM Exporter)은 보조 지표로만 봅니다.
- 배치 처리 위주라면 Deployment 대신 Job/Argo Workflow로 문서 큐를 소비하는 구조도 고려합니다.

### 모니터링

```yaml
# 07-servicemonitor.yaml (Prometheus Operator)
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: uocr2
  namespace: uocr
spec:
  selector:
    matchLabels: {app: uocr2}
  endpoints:
    - port: http
      path: /metrics
      interval: 15s
```

### 트러블슈팅

| 증상 | 원인 | 조치 |
| --- | --- | --- |
| `unknown chat template unlimited-ocr` | 일반 SGLang 이미지 사용 | 커스텀 wheel 이미지로 교체 |
| 기동 중 startupProbe 실패로 재시작 반복 | CUDA graph 캡처가 오래 걸림 | `failureThreshold` 증가, 로그에서 캡처 진행 확인 |
| 대형 할당 OOM (약 462MiB 단일 할당) | SAM 바이어스 청크 기본값 512 | `SGLANG_OPT_UOCR_SAM_REL_POS_BIAS_MB=64` 확인 |
| 동시 요청 증가 시 OOM | KV 예약 과다/프리필 피크 | `mem-fraction-static` 0.7 이하, `max-prefill-tokens` 축소 |
| `Bus error` / shm 관련 오류 | `/dev/shm` 부족 | `dshm` sizeLimit과 `limits.memory` 증가 |
| 긴 문서 응답이 중간에 끊김 | Ingress/LB 타임아웃 | 버퍼링 off, read/send timeout 6000s |
| 같은 문장 반복 출력 | 로짓 프로세서 누락 | `custom_logit_processor`와 `custom_params` 전달 확인 |
| 양자화 모델 로드 실패 | 커스텀 SGLang은 BF16 전용 | 원본 `baidu/Unlimited-OCR-2` 사용 |

### 출처

- [baidu/Unlimited-OCR-2 모델 카드 (Hugging Face)](https://huggingface.co/baidu/Unlimited-OCR-2)
- [baidu/Unlimited-OCR (GitHub)](https://github.com/baidu/Unlimited-OCR)
- [AtomicChat/Unlimited-OCR-2-W4A16 (서빙 엔진 지원 현황 참고)](https://huggingface.co/AtomicChat/Unlimited-OCR-2-W4A16)
