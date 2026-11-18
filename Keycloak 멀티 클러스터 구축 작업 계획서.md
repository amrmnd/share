# Keycloak 멀티 클러스터 구축 작업 계획서

2026-11-17 · Amarmend

## 1. 개요

일반 Kubernetes 클러스터 2개(Site A, Site B)에 Keycloak을 Active-Passive로 구축합니다. DB는 CNPG와 PgBouncer, 세션 캐시는 External Infinispan을 쓰고, 오퍼레이터 3종은 모두 OLM으로 설치합니다.

**목표**

- Site A 전체 장애 시 Site B로 전환해 인증 서비스를 이어간다.
- 전환 절차를 런북으로 만들고 실제 장애 테스트로 검증한다.
- 오퍼레이터와 애플리케이션 버전을 두 사이트에서 같게 유지하는 운영 체계를 만든다.

**확정된 전제조건**

| 항목 | 결정 | 비고 |
| --- | --- | --- |
| 플랫폼 | 일반 Kubernetes | OLM을 직접 설치하고 OperatorHub.io 카탈로그를 씀 |
| 운영 방식 | Active-Passive | Site A가 Active, Site B가 Standby |
| 사이트 | 2개, RTT 10ms 미만 | 저지연 구간이라고 가정 |
| DB 복제 경로 | LoadBalancer | Site A Primary의 복제 엔드포인트를 LoadBalancer Service로 노출 |
| Infinispan cross-site 경로 | LoadBalancer (가정) | Infinispan Operator 기본값을 따름. DB와 같은 방식으로 통일 |
| 글로벌 트래픽 전환(GSLB/DNS) | 미정 | 우선 DNS 수동 전환으로 계획하고, 결정되면 Phase 6에 반영 |

**범위 밖**: 애플리케이션의 Keycloak 연동 변경, 기존 Keycloak 데이터 이관(필요하면 별도 계획).

## 2. 목표 아키텍처

두 사이트에 Keycloak, Infinispan, PgBouncer, CNPG를 같은 구성으로 두고, 사이트 간에는 DB 복제와 Infinispan cross-site 두 경로만 연결합니다.

> [다이어그램: 목표 아키텍처 · 2사이트 Active-Passive — 원본 문서 참고]

Keycloak은 같은 사이트의 Pooler와 Infinispan만 바라봅니다. 사이트 간 통신은 두 경로뿐이고 둘 다 LoadBalancer를 지납니다. Site B의 점선 연결은 승격 후에만 쓰입니다.

## 3. 버전 및 호환성 매트릭스

버전은 Phase 0에서 한 번 확정하고, 두 사이트에 같은 버전을 고정합니다. 아래 표의 "확정 버전" 칸은 착수 시점에 채웁니다.

| 구성요소 | OLM 패키지 (OperatorHub.io) | 확정 버전 | 확인할 점 |
| --- | --- | --- | --- |
| OLM | - |  | OperatorHub.io 설치 스크립트가 설치하는 OLM v0 계열 기준 |
| Keycloak Operator / Keycloak | keycloak-operator |  | Operator 버전 = Keycloak 버전. 멀티 사이트 가이드의 대상 버전인지 확인 |
| Infinispan Operator / Infinispan Server | infinispan |  | 해당 Keycloak 버전이 지원하는 Infinispan 메이저 버전과 일치해야 함 |
| CloudNativePG Operator | cloudnative-pg |  | Replica Cluster와 Distributed Topology(선언적 승격) 지원 버전 |
| PostgreSQL | - (CNPG 이미지) |  | Keycloak이 지원하는 PostgreSQL 메이저 버전 |
| PgBouncer | - (CNPG Pooler 내장) |  | CNPG 버전에 묶인 이미지. transaction 모드를 쓸 경우에만 prepared statement 지원 여부가 중요 |
| Kubernetes | - |  | 세 오퍼레이터의 지원 버전 범위의 교집합 |

원칙: 두 사이트는 항상 같은 버전을 씁니다. 업그레이드는 Standby(Site B)부터 진행합니다(Phase 8).

## 4. Phase 1 — 인프라 준비

두 클러스터를 같은 사양으로 준비하고, 사이트 간 LoadBalancer 통신을 먼저 검증합니다. 이 단계가 끝나면 두 클러스터에서 상대편 LoadBalancer IP로 TCP 접속이 되어야 합니다.

- [ ] 클러스터 2개 준비: Kubernetes 버전, 노드 사양, 가용영역(AZ) 분산을 동일하게
- [ ] StorageClass 준비: CNPG와 Infinispan용 블록 스토리지, `volumeBindingMode: WaitForFirstConsumer`, 볼륨 확장 허용
- [ ] LoadBalancer 구현체 확인: 클라우드 LB 또는 MetalLB 등. 사이트 간 라우팅이 되는 IP 대역인지 확인
- [ ] LoadBalancer IP 고정: DB 복제용 1개, Infinispan cross-site용 1개를 사이트마다 예약
- [ ] 방화벽: 사이트 간에는 PostgreSQL(5432), Infinispan Gossip Router 포트만 상대 사이트 대역에 허용
- [ ] 인증서: cert-manager 설치. Keycloak Ingress, DB 복제(TLS), Infinispan cross-site(TLS)용 인증서 발급 체계
- [ ] 객체 스토리지: CNPG 백업과 WAL 아카이브용 버킷. 두 사이트가 모두 읽을 수 있어야 함(Replica Cluster 초기 구축과 failback에 필요)
- [ ] Ingress Controller: 사이트별 Keycloak 외부 노출용
- [ ] 모니터링 기반: Prometheus Operator(ServiceMonitor/PodMonitor CRD) 설치
- [ ] 사이트 간 지연 측정: RTT 10ms 미만 가정을 실측으로 기록

**완료 기준**: Site A 파드에서 Site B LoadBalancer IP의 테스트 포트로 접속되고, 그 반대도 됩니다.

## 5. Phase 2 — OLM 및 오퍼레이터 설치

일반 Kubernetes에는 OLM을 직접 설치하고, 오퍼레이터 3종을 Subscription으로 설치합니다. 모든 Subscription은 `installPlanApproval: Manual`과 `startingCSV`로 버전을 고정합니다.

**작업 항목**

- [ ] OLM 설치: OperatorHub.io의 `install.sh`(또는 `operator-sdk olm install`)로 두 클러스터에 같은 버전 설치
- [ ] CatalogSource 고정: 기본 `operatorhubio-catalog`는 계속 갱신되므로, 카탈로그 이미지를 digest로 고정하거나 내부 레지스트리로 미러링
- [ ] 네임스페이스와 OperatorGroup 생성 (아래 표)
- [ ] Subscription 생성 후 InstallPlan을 수동 승인
- [ ] CSV 상태 `Succeeded`와 CRD 생성 확인
- [ ] 위 매니페스트를 Git으로 관리해 두 사이트에 같은 내용으로 적용

**배치안**

| 오퍼레이터 | 네임스페이스 | OperatorGroup 범위 | 비고 |
| --- | --- | --- | --- |
| CloudNativePG | `operators` | AllNamespaces (기본 `global-operators`) | DB는 `keycloak-db` 네임스페이스에 생성 |
| Infinispan | `infinispan` | OwnNamespace | Infinispan 클러스터도 같은 네임스페이스 |
| Keycloak | `keycloak` | OwnNamespace | Keycloak Operator는 네임스페이스 단위로 동작 |

채널 이름과 지원 설치 모드는 카탈로그의 `PackageManifest`에서 확인하고 확정합니다.

**예시 — Keycloak Operator**

```yaml
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: keycloak-og
  namespace: keycloak
spec:
  targetNamespaces:
    - keycloak
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: keycloak-operator
  namespace: keycloak
spec:
  name: keycloak-operator
  source: operatorhubio-catalog
  sourceNamespace: olm
  channel: <확인 후 기입>
  installPlanApproval: Manual
  startingCSV: keycloak-operator.v<버전>
```

**완료 기준**: 두 클러스터에서 오퍼레이터 3종의 CSV가 같은 버전으로 `Succeeded`이고, 자동 업그레이드가 꺼져 있습니다.

## 6. Phase 3 — DB (CNPG + PgBouncer)

Site A에 Primary Cluster를, Site B에 Replica Cluster를 두고 CNPG Distributed Topology로 묶습니다. Site B는 Site A의 LoadBalancer를 통해 스트리밍 복제를 받고, 객체 스토리지의 WAL 아카이브를 보조 경로로 씁니다.

**복제 특성 (반드시 합의할 것)**

- 사이트 내부: 인스턴스 3개, 동기 복제 1개 이상 → 사이트 내 노드 장애 시 RPO 0
- 사이트 간: 비동기 스트리밍 → Site A 전체 장애 시 마지막 몇 초의 커밋이 유실될 수 있음(RPO > 0)
- 계획된 switchover는 Distributed Topology의 선언적 승격 절차로 데이터 유실 없이 가능

**작업 항목**

- [ ] 공용 CA 준비: 두 Cluster의 서버 인증서와 `streaming_replica` 클라이언트 인증서를 같은 CA(cert-manager)에서 발급. 사이트 간 복제는 인증서 인증으로 연결
- [ ] 백업 구성: Barman Cloud Plugin으로 객체 스토리지에 베이스 백업과 WAL 아카이브. 이 플러그인은 OLM 밖에서 매니페스트로 설치되므로 버전 관리 대상에 추가
- [ ] Site A Cluster 생성: `managed.services.additional`로 rw 대상 LoadBalancer Service 추가(고정 IP, 상대 사이트 대역만 허용). Site B에도 같은 Service를 만들어 승격 후 역방향 복제에 대비
- [ ] Site B Cluster 생성: `externalClusters`에 Site A LoadBalancer를 적고, `pg_basebackup` 또는 객체 스토리지 복구로 부트스트랩
- [ ] Distributed Topology 설정: 두 Cluster 모두 `replica.primary`와 `replica.source`를 선언하고, 상대편을 `externalClusters`로 서로 등록
- [ ] Keycloak DB/사용자 생성: `bootstrap.initdb`의 database/owner 또는 `Database` CR. 비밀번호 Secret은 두 사이트에 같은 값으로 배포
- [ ] Pooler 생성: 사이트마다 `type: rw` Pooler 1개, 인스턴스 2개 이상
- [ ] 복제 지연 모니터링: Site B의 WAL 수신/재생 지연을 알람으로 등록

**PgBouncer 설정 원칙**

- `poolMode: session`으로 시작합니다. Keycloak(Hibernate/JDBC)이 prepared statement를 쓰기 때문입니다.
- session 모드에서는 서버 커넥션 수 = 클라이언트 커넥션 수입니다. `default_pool_size`는 Keycloak 파드 수 × `db-pool-max-size` 이상으로 잡고, PostgreSQL `max_connections` 안에 들어오게 합니다.
- transaction 모드는 성능 테스트에서 커넥션 부족이 확인될 때만 검토합니다(`max_prepared_statements` 설정과 Keycloak 스키마 마이그레이션 검증 필요).

**예시 — Site B Replica Cluster와 Pooler (핵심 필드만)**

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: kc-db-site-b
  namespace: keycloak-db
spec:
  instances: 3
  replica:
    primary: kc-db-site-a        # 현재 Primary인 클러스터
    source: kc-db-site-a
  bootstrap:
    pg_basebackup:
      source: kc-db-site-a
  externalClusters:
    - name: kc-db-site-a
      connectionParameters:
        host: <Site A LoadBalancer IP>
        user: streaming_replica
        dbname: postgres
        sslmode: verify-full
      sslKey:  { name: kc-db-replication, key: tls.key }
      sslCert: { name: kc-db-replication, key: tls.crt }
      sslRootCert: { name: kc-db-ca, key: ca.crt }
---
apiVersion: postgresql.cnpg.io/v1
kind: Pooler
metadata:
  name: kc-db-pooler-rw
  namespace: keycloak-db
spec:
  cluster:
    name: kc-db-site-b
  instances: 2
  type: rw
  pgbouncer:
    poolMode: session
    parameters:
      max_client_conn: "1000"
      default_pool_size: "<산정값>"
```

**완료 기준**: Site A에 쓴 데이터가 Site B에서 조회되고, 양쪽 Pooler로 접속되며, 객체 스토리지 백업으로 별도 네임스페이스에 복구됩니다.

## 7. Phase 4 — External Infinispan

사이트마다 Infinispan 클러스터를 두고, cross-site 백업으로 Keycloak 캐시를 상대 사이트에 복제합니다. 두 클러스터는 상대편 LoadBalancer(Gossip Router)의 고정 주소로 연결합니다.

**작업 항목**

- [ ] Infinispan CR 생성: `service.type: DataGrid`, replicas 3, 사이트 이름 `site-a` / `site-b`
- [ ] cross-site 노출: `service.sites.local.expose.type: LoadBalancer`, 고정 IP
- [ ] 상대 사이트 등록: `service.sites.locations`에 정적 URL(`infinispan+xsite://<상대 LB IP>:<포트>`)을 적음. 상대 클러스터 Kubernetes API 접근이 필요 없는 방식
- [ ] cross-site TLS: `sites.local.encryption`에 transport keystore/truststore Secret 지정. CA는 양 사이트 공용
- [ ] 인증: Keycloak이 쓸 Infinispan 사용자/비밀번호를 identities Secret으로 생성. 양 사이트 같은 값
- [ ] Keycloak용 캐시 생성: Keycloak 멀티 사이트 가이드의 캐시 목록(예: `sessions`, `clientSessions`, `offlineSessions`, `offlineClientSessions`, `authenticationSessions`, `actionTokens`, `loginFailures`, `work`)을 `Cache` CR로 미리 생성
- [ ] 백업 전략: 각 캐시에 상대 사이트 백업을 가이드 권장값(SYNC)으로 설정하고, 상대 사이트 장애 시 offline 처리 정책(`take-offline`) 지정
- [ ] 메트릭: ServiceMonitor로 cross-site 상태와 백업 지연 수집

**예시 — Site A Infinispan (핵심 필드만)**

```yaml
apiVersion: infinispan.org/v1
kind: Infinispan
metadata:
  name: infinispan
  namespace: infinispan
spec:
  replicas: 3
  service:
    type: DataGrid
    sites:
      local:
        name: site-a
        expose:
          type: LoadBalancer
        encryption:
          transportKeyStore:
            secretName: xsite-keystore
          routerKeyStore:
            secretName: xsite-keystore
          trustStore:
            secretName: xsite-truststore
      locations:
        - name: site-b
          url: infinispan+xsite://<Site B LB IP>:<포트>
  security:
    endpointSecretName: kc-infinispan-identities
```

캐시 정의 XML/YAML은 확정한 Keycloak 버전의 가이드에 있는 것을 그대로 쓰고, 임의로 바꾸지 않습니다.

**완료 기준**: 두 사이트 Infinispan에서 cross-site 뷰에 상대 사이트가 online으로 보이고, Site A 캐시에 넣은 항목이 Site B에서 조회됩니다.

## 8. Phase 5 — Keycloak

두 사이트에 같은 Keycloak CR을 두되, Site B는 평소에 인스턴스 0개로 둡니다. Site B DB는 읽기 전용 Replica라서 Keycloak이 기동하며 쓸 수 없기 때문입니다.

**작업 항목**

- [ ] Secret 준비: DB 계정, Infinispan 계정, TLS 인증서. 두 사이트 같은 값
- [ ] DB 연결: `db.host`는 CNPG 클러스터가 아니라 같은 사이트 Pooler Service(`kc-db-pooler-rw.keycloak-db.svc`)를 가리킴
- [ ] remote cache 연결: `multi-site` 기능 활성화, `cache-remote-host`는 같은 사이트 Infinispan Service, TLS 사용
- [ ] hostname: 두 사이트 모두 같은 공개 hostname(예: `sso.example.com`). 그래야 DNS 전환만으로 failover가 됨
- [ ] Ingress와 인증서: 사이트마다 같은 hostname으로 발급
- [ ] health/metrics 활성화: 사이트 상태 판단용 `/lb-check` 확인
- [ ] Site A: `instances: 3`으로 배포, Realm 초기 구성은 Site A에서만 수행(데이터는 DB 복제로 Site B에 전달)
- [ ] Site B: `instances: 0`으로 배포. 승격 리허설에서 3으로 올려 기동 확인
- [ ] 리소스/JVM: 파드당 CPU·메모리와 `db-pool-max-size`를 성능 테스트로 확정

**예시 — Keycloak CR (핵심 필드만)**

```yaml
apiVersion: k8s.keycloak.org/v2alpha1
kind: Keycloak
metadata:
  name: keycloak
  namespace: keycloak
spec:
  instances: 3            # Site B는 0
  db:
    vendor: postgres
    host: kc-db-pooler-rw.keycloak-db.svc
    database: keycloak
    usernameSecret: { name: kc-db-app, key: username }
    passwordSecret: { name: kc-db-app, key: password }
  hostname:
    hostname: https://sso.example.com
  http:
    tlsSecret: keycloak-tls
  features:
    enabled:
      - multi-site
  additionalOptions:
    - name: cache-remote-host
      value: infinispan.infinispan.svc
    - name: cache-remote-port
      value: "11222"
    - name: cache-remote-username
      secret: { name: kc-infinispan-cred, key: username }
    - name: cache-remote-password
      secret: { name: kc-infinispan-cred, key: password }
    - name: db-pool-max-size
      value: "<산정값>"
```

옵션 이름은 확정한 Keycloak 버전의 멀티 사이트 가이드와 대조해 최종 확인합니다.

**완료 기준**: Site A에서 로그인하면 세션이 Site B Infinispan에도 보이고, Site A의 `/lb-check`가 정상을 반환합니다.

## 9. Phase 6 — Failover / Failback 절차

전환은 사람이 결정하고 런북으로 실행합니다(GSLB 미정이라 DNS 수동 전환 기준). 핵심 원칙은 한 시점에 쓰기 가능한 DB와 기동 중인 Keycloak이 한 사이트에만 있는 것입니다.

**A. 계획된 switchover (Site A → Site B, 데이터 유실 없음)**

1. 점검 시간 공지, Site B 복제 지연이 0에 가까운지 확인
2. Site A Keycloak을 `instances: 0`으로 내려 쓰기를 멈춤
3. Site A Cluster의 `replica.primary`를 `kc-db-site-b`로 바꿔 강등(demote)하고, status에 나온 demotion token을 확보
4. Site B Cluster에 `replica.primary: kc-db-site-b`와 `promotionToken`을 설정해 승격
5. Site B DB가 쓰기 가능하고, Site A가 Site B의 Replica로 복제 중인지 확인
6. Site B Keycloak을 `instances: 3`으로 올리고 `/lb-check` 확인
7. DNS를 Site B Ingress로 전환하고 로그인/토큰 갱신 확인

**B. 장애 시 failover (Site A 전체 불가)**

1. 장애 선언: 담당자가 Site A 복구 불가를 판단(판단 기준과 대기 시간은 런북에 명시)
2. Site B Infinispan에서 `site-a` 백업을 offline으로 전환
3. Site B Cluster를 token 없이 승격. 마지막 미복제 커밋 유실을 감수하는 결정이므로 승인자 명시
4. Site B Keycloak을 `instances: 3`으로 올리고 `/lb-check` 확인
5. DNS를 Site B로 전환
6. Site A 복구 전 격리: Site A가 돌아오기 전에 Keycloak을 0으로, Site A Cluster의 `replica.primary`를 `kc-db-site-b`로 바꿔 split-brain을 막음

**C. Failback (Site B → Site A)**

1. Site A DB를 Site B의 Replica로 재구성. 장애 후에는 이전 타임라인이 갈라져 있을 수 있으므로 볼륨을 비우고 다시 부트스트랩하는 것을 기본으로 함
2. Site A Infinispan cross-site를 online으로 되돌리고 상태 전송(state transfer)으로 캐시 동기화
3. 이후 A의 계획된 switchover 절차를 방향만 바꿔 수행

각 절차는 실행 시간을 측정해 RTO 목표를 확정합니다.

## 10. Phase 7 — 검증 계획

운영 전환 전에 아래 시나리오를 모두 통과해야 합니다. 장애 시나리오는 부하를 걸어둔 상태에서 수행하고, 실측 RPO와 RTO를 기록합니다.

| # | 시나리오 | 방법 | 기대 결과 |
| --- | --- | --- | --- |
| 1 | 기본 기능 | Site A에서 로그인, 토큰 발급/갱신, 로그아웃 | 정상 동작, 세션이 Site B Infinispan에 복제 |
| 2 | Keycloak 파드 장애 | Site A Keycloak 파드 1개 삭제 | 서비스 유지, 세션 유지 |
| 3 | DB Primary 파드 장애 | Site A CNPG Primary 파드 삭제 | 사이트 내 자동 failover, 데이터 유실 없음, Pooler 경유 재접속 |
| 4 | Pooler 파드 장애 | PgBouncer 파드 1개 삭제 | 일시적 재연결 후 정상 |
| 5 | Infinispan 파드 장애 | Site A Infinispan 파드 1개 삭제 | 세션 유지 |
| 6 | 사이트 간 네트워크 단절 | LoadBalancer 구간 차단 | Site A 서비스 유지(cross-site offline 전환), 복구 후 DB/캐시 재동기화 |
| 7 | 계획된 switchover | Phase 6 A 절차 | 데이터 유실 없음, 로그인 세션 유지 |
| 8 | 사이트 전체 장애 | Site A 노드 전체 중지 후 Phase 6 B 절차 | Site B에서 서비스 재개, 실측 RPO/RTO 기록 |
| 9 | Failback | Phase 6 C 절차 | Site A 재구성 후 정상 복귀, split-brain 없음 |
| 10 | 백업 복구 | 객체 스토리지에서 특정 시점(PITR)으로 별도 클러스터 복구 | 복구된 DB로 Keycloak 기동 |
| 11 | 부하 테스트 | 목표 로그인/초 부하(목표치 미정) | 응답 지연과 DB 커넥션 사용량 기록, PgBouncer 모드와 풀 크기 확정 |
| 12 | 오퍼레이터 업그레이드 | 스테이징에서 InstallPlan 승인 | 서비스 중단 없이 또는 계획된 중단 내 완료 |

## 11. Phase 8 — 운영

운영 단계의 핵심은 Site B가 언제든 승격 가능한 상태인지 계속 확인하는 것입니다.

**모니터링/알람**

- CNPG: Site B 복제 지연(바이트/초), WAL 아카이브 실패, 마지막 백업 시각, 커넥션 사용률
- PgBouncer: 대기 클라이언트 수, 풀 포화
- Infinispan: cross-site 상태(online/offline), 백업 실패 건수
- Keycloak: `/lb-check`, 로그인 실패율, 응답 지연
- OLM: 승인 대기 InstallPlan 존재 여부(알림만, 자동 승인 금지)

**업그레이드 원칙**

1. 릴리스 노트와 호환성 매트릭스 갱신
2. 스테이징 환경에서 InstallPlan 승인과 검증 시나리오 1, 7 수행
3. Site B(Standby) 먼저, 이어서 Site A 업그레이드
4. 순서는 CNPG → Infinispan → Keycloak. Keycloak 메이저 업그레이드는 DB 스키마가 바뀌므로 점검 시간에 진행

**런북 목록**

- [ ] 계획된 switchover / 장애 failover / failback
- [ ] Infinispan cross-site offline/online 전환
- [ ] DB 백업 복구(PITR)
- [ ] 오퍼레이터 업그레이드와 롤백
- [ ] 인증서 갱신(복제용, cross-site용 포함)
- [ ] 정기 DR 훈련: 분기 1회 switchover 실습

## 12. 리스크, 미결정 사항, 일정

**리스크 및 대응**

| 리스크 | 영향 | 대응 |
| --- | --- | --- |
| 사이트 간 DB 복제가 비동기 | Site A 전체 장애 시 마지막 커밋 유실(RPO > 0) | 복제 지연 알람, 허용 RPO를 사전에 합의, 계획 전환은 token 기반 switchover만 사용 |
| 장애 후 split-brain | 두 사이트에 쓰기 발생, 데이터 불일치 | 복구 전 Site A 격리 절차(Phase 6 B-6), Site A DB는 재부트스트랩 |
| PgBouncer 모드 불일치 | prepared statement 오류, 마이그레이션 실패 | session 모드로 시작, transaction 모드는 부하 테스트로 검증 후에만 |
| OLM 자동 업그레이드로 버전 불일치 | 사이트 간 호환성 깨짐 | Manual 승인, 카탈로그 이미지 digest 고정 |
| Keycloak-Infinispan 버전 불일치 | remote cache 연결 실패 | 호환성 매트릭스 기준으로 함께 업그레이드 |
| LoadBalancer 구간 노출 | DB/Infinispan 포트가 외부에 열릴 위험 | 상대 사이트 대역만 허용(`loadBalancerSourceRanges`), TLS와 인증서 인증 |
| Barman Cloud Plugin이 OLM 밖 | 버전 관리 누락 | 버전 매트릭스와 Git 매니페스트에 포함 |

**미결정 사항**

- [ ] GSLB/DNS 전환 방식(수동 DNS, GSLB 제품, DNS TTL)
- [ ] 목표 RPO/RTO 수치
- [ ] 성능 목표(동시 사용자, 초당 로그인 수)
- [ ] 사용할 Keycloak/Infinispan/CNPG 버전
- [ ] 스테이징 환경 별도 구성 여부

**일정**: 착수일과 투입 인력이 정해지면 Phase별 기간을 채웁니다. Phase 1–5는 순서대로 진행하고(Phase 3과 4는 병행 가능), Phase 6–7은 반복하며 런북을 다듬습니다.
