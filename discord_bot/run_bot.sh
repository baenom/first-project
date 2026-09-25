#!/usr/bin/env bash
cd "$(dirname "$0")"
if [ ! -f .env ] && [ -z "$DISCORD_BOT_TOKEN" ]; then
    echo "=========================================================="
    echo "DISCORD_BOT_TOKEN 환경변수 또는 .env 파일이 필요합니다."
    echo "예시: echo 'DISCORD_BOT_TOKEN=내_토큰' > .env"
    echo "=========================================================="
fi
pip3 install -r requirements.txt -q
python3 bot.py
