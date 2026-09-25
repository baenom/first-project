@echo off
cd /d "%~dp0"
if not defined DISCORD_BOT_TOKEN (
    if not exist .env (
        echo ==========================================================
        echo DISCORD_BOT_TOKEN 환경변수 또는 .env 파일이 필요합니다.
        echo 예시: echo DISCORD_BOT_TOKEN=내_토큰 > .env
        echo ==========================================================
    )
)
pip install -r requirements.txt -q
python bot.py
pause
