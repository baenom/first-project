# SyncRoom UDP SFU Relay Server (초저지연 합주 중계 서버)

경기도-서울 등 원거리(약 20~50km)에서 오디오 인터페이스(오인페) 신호를 무압축(PCM)으로 실시간 중계하기 위해 제작된 C++ 초경량 UDP SFU(Selective Forwarding Unit) 서버입니다.

---

## 1. 아키텍처 개요

- **프로토콜**: 저지연 UDP (Uncompressed 48kHz 16-bit PCM)
- **중계 방식**: Selective Forwarding (전송자 제외 동일 방 참가자에게 Zero-Copy 즉시 포워딩)
- **지연 시간 (Latency)**: 국내 FTTH 광랜 기준 RTT 2~6ms + 오인페 버퍼 1.33~2.67ms = 총 지연 약 5~10ms (체감 불가 수준)
- **대역폭**: 1명당 약 768kbps ~ 1.5Mbps (일반 가정용 100M/500M 인터넷에서 5~6명 동시 합주 여유)

---

## 2. 홈 NAS (Synology / QNAP / Linux) 배포 방법

### A. Docker Compose 이용 (가장 추천)
1. NAS의 `docker` 폴더(예: `/volume1/docker/syncroom-sfu`)에 이 `SFU` 폴더 전체를 업로드합니다.
2. 터미널(SSH)에서 아래 명령어를 실행하거나 시놀로지 Container Manager에서 프로젝트를 생성합니다:
   ```bash
   cd SFU
   docker compose up -d --build
   ```
3. **공유기 포트포워딩**:
   - 외부 포트: `UDP 9999`
   - 내부 IP: `내 NAS의 로컬 IP`
   - 내부 포트: `UDP 9999`

---

## 3. 로컬에서 직접 빌드 및 테스트

### macOS / Linux
```bash
cd SFU
mkdir -p build && cd build
cmake -DCMAKE_BUILD_TYPE=Release ..
cmake --build .
./sfu_server 9999
```

### Windows
```cmd
cd SFU
mkdir build && cd build
cmake ..
cmake --build . --config Release
Release\sfu_server.exe 9999
```

---

## 4. 패킷 구조 (protocol.h)
- `SYNC_MAGIC` (0x53594E43) 헤더 검증
- Type 1: Room Join
- Type 2: Room Leave
- Type 3: Audio PCM Data (128 samples / packet)
- Type 4/5: Ping / Pong RTT 측정
- 5초간 무응답 참여자 세션 자동 회수 (Keepalive)
