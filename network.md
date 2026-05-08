# [기술 문서] 리눅스 에페머럴 포트 관리 및 커널 최적화 가이드

리눅스 커널의 에페머럴 포트(Ephemeral Port) 할당 메커니즘을 이해하고, 포트 고갈 현상을 해결하기 위한 모니터링 및 커널 파라미터 최적화 방법을 설명합니다.

---

## 1. 에페머럴 포트(Ephemeral Port) 메커니즘

리눅스 커널은 외부 연결(Outbound) 시 소스 포트를 할당하기 위해 전역 카운터를 사용하지 않고, 보안과 효율성을 위해 특정 알고리즘에 따라 가용 포트를 선택합니다.

### 1.1 포트 선택 및 할당 방식
* **해시 기반 검색**: 커널은 `inet_csk_get_port`(TCP) 또는 `udp_lib_get_port`(UDP) 함수를 통해 포트를 찾습니다.
* **무작위 오프셋(Random Offset)**: 포트 예측 공격을 방어하기 위해 설정된 범위 내에서 임의의 시작 지점을 생성하여 가용 포트를 탐색합니다.
* **충돌 검사**: 선택한 포트가 이미 사용 중이거나 리스닝(Listening) 상태인지 확인한 후, 사용 가능할 때까지 다음 포트로 이동하며 검색합니다.

### 1.2 포트 범위 확인 및 수정
* **확인**: `cat /proc/sys/net/ipv4/ip_local_port_range`
* **수정 (임시)**: `echo "1024 65535" > /proc/sys/net/ipv4/ip_local_port_range`
* **수정 (영구)**: `/etc/sysctl.conf`에 `net.ipv4.ip_local_port_range = 1024 65535` 추가

---

## 2. 포트 사용 현황 모니터링

시스템의 포트 고갈 여부를 판단하기 위해 현재 점유된 소켓 상태를 확인해야 합니다.

### 2.1 주요 모니터링 명령어
* **상태별 요약 통계 확인**:
  ```bash
  ss -s
  ```
  *결과 예시: `TCP: 500 (estab 100, closed 350, orphaned 0, timewait 340)`*

* **TIME_WAIT 상태 포트 개수 확인**:
  ```bash
  ss -ant | grep TIME-WAIT | wc -l
  ```

* **전체 에페머럴 포트 사용량 계산**:
  ```bash
  ss -ant | awk '{print $1}' | grep -E "ESTAB|TIME-WAIT|CLOSE-WAIT" | wc -l
  ```

---

## 3. 커널 최적화 설정 (`tcp_tw_reuse`)

아웃바운드 연결이 매우 많은 환경에서는 `TIME_WAIT` 소켓이 누적되어 새로운 연결이 불가능한 '포트 고갈(Port Exhaustion)' 현상이 발생합니다.

### 3.1 `net.ipv4.tcp_tw_reuse`
* **개념**: `TIME_WAIT` 상태인 소켓을 프로토콜 관점에서 안전하다고 판단될 경우 새로운 연결에 즉시 재사용합니다.
* **필수 조건**: `net.ipv4.tcp_timestamps = 1` (기본값 1)이 활성화되어 있어야 합니다.

### 3.2 설정 방법
1. **실시간 적용**:
   ```bash
   sudo sysctl -w net.ipv4.tcp_tw_reuse=1
   ```
2. **영구 적용**:
   `/etc/sysctl.conf` 파일 끝에 아래 내용 추가:
   ```text
   net.ipv4.tcp_tw_reuse = 1
   ```
   이후 설정 로드: `sudo sysctl -p`

---

## 4. 주의 사항 및 결론

* **NAT 환경 주의**: 클라이언트가 NAT(공유기 등) 환경 뒤에 있을 경우, 포트 재사용 시 타임스탬프 불일치로 인해 패킷이 드랍될 수 있습니다.
* **에러 메시지**: 포트 고갈 시 애플리케이션 레벨에서 `Cannot assign requested address (EADDRNOTAVAIL)` 에러가 발생합니다.
* **권장 조치**: 고부하 서버 환경에서는 `ip_local_port_range` 확장과 `tcp_tw_reuse` 활성화를 동시에 고려해야 합니다.
