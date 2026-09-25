# SyncRoom (gam) 디스코드 봇 & ZeroTier 가상 랜 가이드 (Mac & Windows)

디스코드 채널에서 명령어를 치면:
1. **ZeroTier 1회용 P2P 가상 회선**을 100% 무료 중앙 API로 자동 생성
2. 참여자들에게 **원클릭 다이렉트 실행 링크(`gam://`)**를 전송하여 로그인/키체인 없이 즉시 입장
3. 합주가 끝나면 `/합주실종료` 명령어로 가상 회선이 흔적 없이 완전 삭제(폭파)되어 원래 네트워크로 100% 복구됩니다.

---

## 1. 사전 준비 및 토큰 발급

### (1) Discord 봇 토큰 발급
1. [Discord Developer Portal](https://discord.com/developers/applications) 접속 및 로그인.
2. 우측 상단 **New Application** 클릭 후 이름 입력 (예: `SyncRoom Bot`).
3. 좌측 **Bot** 메뉴 $\rightarrow$ **Reset Token** 클릭하여 **Bot Token** 복사.
4. 같은 페이지 아래 **Privileged Gateway Intents** 섹션에서:
   - **Message Content Intent** 를 반드시 **ON (체크)** 해주세요.
5. 좌측 **OAuth2** $\rightarrow$ **URL Generator** 메뉴:
   - SCOPES: `bot`, `applications.commands` 체크
   - BOT PERMISSIONS: `Send Messages`, `Embed Links`, `Read Message History`, `Attach Files` 체크
   - 생성된 URL을 웹 브라우저에 붙여넣어 합주 디스코드 서버로 봇을 초대합니다.

### (2) ZeroTier API 토큰 발급 (무료 가상 회선 자동 생성용)
1. [ZeroTier Central](https://my.zerotier.com/) 접속 및 무료 회원가입/로그인.
2. 상단 메뉴 **Account** $\rightarrow$ **Access Tokens** 이동.
3. **Generate Token** 클릭 후 이름(예: `gam-bot`) 입력 후 생성된 토큰 복사.
4. *(참고: 무료 플랜에서 최대 25개 동시 연결 디바이스 지원, 네트워크 생성/삭제 무제한 무료 $0)*

### (3) 환경 설정 파일(.env) 작성
`discord_bot` 폴더 내에 `.env` 파일을 생성하거나 `.env.example`을 복사합니다:
```bash
cp .env.example .env
```
`.env` 파일에 발급받은 값을 입력합니다:
```env
DISCORD_BOT_TOKEN="여기에_디스코드_봇_토큰_입력"
ZEROTIER_API_TOKEN="여기에_ZeroTier_API_토큰_입력"
```

---

## 2. 봇 실행 방법

### macOS / Linux
```bash
cd discord_bot
pip3 install -r requirements.txt
./run_bot.sh
```

### Windows
```cmd
cd discord_bot
pip install -r requirements.txt
run_bot.bat
```

봇이 실행되면 콘솔에 다음과 같이 표시됩니다:
```
=======================================================
🎸 SyncRoom 디스코드 봇 로그인 성공: SyncRoom Bot#1234
OS 환경: darwin (macOS / Windows 호환)
🌐 ZeroTier Central API 연동 활성화: 1회용 가상 회선 자동 생성 준비 완료
🌐 원클릭 리다이렉트 웹 서버 가동: http://localhost:8765/open
=======================================================
✅ 슬래시 명령어 2개 동기화 완료
```

---

## 3. 디스코드에서 사용법

### (1) 합주실 개설
채팅방에 아래 슬래시 명령어를 입력합니다:
```
/합주실개설 방이름:퇴근길 재즈 잼
```
- 봇이 ZeroTier 1회용 가상 네트워크(예: `8056c2e21c...`)를 즉시 자동 생성합니다.
- 합주 참여 카드와 함께 **[👑 방장으로 앱 실행]**, **[🎧 게스트로 합주실 참가]** 버튼이 생성됩니다.

### (2) 앱 원클릭 실행 & 가상 랜 자동 참가
- 버튼을 누르면 브라우저 팝업을 거쳐 Mac 또는 Windows의 `gam` 앱이 즉시 실행됩니다.
- 앱 실행 시 디스코드 닉네임으로 자동 로그인되며, 해당 합주실의 1회용 가상 랜에 자동으로 참여합니다.
- 복잡한 IP 입력이나 방 번호 입력 없이 즉시 연결됩니다!

### (3) 합주실 종료 & 가상 회선 자동 폭파
합주가 끝나면 개설했던 방 번호로 종료 명령어를 실행합니다:
```
/합주실종료 방번호:1
```
- ZeroTier 가상 회선이 영구 삭제(폭파)되어 원래 네트워크 환경으로 완벽히 복원됩니다.
- 불필요한 가상 네트워크가 남아있지 않으므로 항상 깨끗한 상태가 유지됩니다.
