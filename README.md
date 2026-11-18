# share

Kubernetes 인프라 작업 중에 만든 문서, 매니페스트, 참고 자료 모음입니다.

## 문서 (`docs/`)

| 문서 | 내용 |
| --- | --- |
| [Keycloak 멀티 클러스터 구축 작업 계획서](docs/Keycloak%20멀티%20클러스터%20구축%20작업%20계획서.md) | 2사이트 Active-Passive Keycloak 구축 계획 (CNPG + PgBouncer, External Infinispan, OLM) |
| [Unlimited-OCR-2 Kubernetes 배포 가이드](docs/Unlimited-OCR-2%20Kubernetes%20배포%20가이드.md) | Unlimited-OCR-2 모델의 Kubernetes 배포 절차 |
| [리눅스 에페머럴 포트 관리 및 커널 최적화 가이드](docs/network.md) | 에페머럴 포트 고갈 모니터링과 커널 파라미터 튜닝 |

## Kubernetes 매니페스트 (`k8s/`)

| 폴더 | 파일 | 내용 |
| --- | --- | --- |
| [`keycloak/`](k8s/keycloak) | `keycloak_realm_migration.yaml` | Realm export Job과 PVC |
| | `kc-infinispan-config.yaml` | Keycloak용 Infinispan 설정 ConfigMap |
| | `ispn-console-ingress.yaml` | Infinispan 콘솔 Ingress |
| [`llm/`](k8s/llm) | `vllm_deployment.yaml` | vLLM으로 DeepSeek-R1 서빙 |
| | `glm5.3-flash.yaml` | vLLM으로 GLM-5.3-Flash 서빙 |
| | `unlimitedocr-2-deployment.yaml` | Unlimited-OCR-2 Deployment ([배포 가이드](docs/Unlimited-OCR-2%20Kubernetes%20배포%20가이드.md)) |
| [`paddleocr-vl/`](k8s/paddleocr-vl) | `01-*.yaml`, `02-*.yaml` | PaddleOCR-VL (vLLM + 공식 파이프라인 API). 자세한 내용은 [README](k8s/paddleocr-vl/README.md) |
| [`kyverno/`](k8s/kyverno) | `install-kyverno.sh` | Kyverno Helm 설치 명령과 values |
| | `kyverno_clusterpolicy.yaml` | 스케줄링 실패 PVC에 annotation을 다는 ClusterPolicy |
| [`kubevirt/`](k8s/kubevirt) | `kubevirt-win10-vm.yaml` | KubeVirt Windows 10 VM |

## Helm 차트 (`charts/`)

- `alloy-1.0.3.tgz` — Grafana Alloy
- `loki-6.30.0.tgz` — Grafana Loki

## 참고 도서 (`books/`)

인프라·성능·네트워크 관련 PDF 자료입니다.
