#!/usr/bin/env python3
"""
SyncRoom (gam) Discord Bot with Automated ZeroTier Virtual LAN
- 크로스 플랫폼 지원 (macOS & Windows 완벽 호환)
- 디스코드에서 원클릭으로 합주실을 개설하고 참여자를 앱으로 다이렉트 초대합니다.
- ZeroTier Central API 연동: 개설 시 1회용 가상 랜 자동 생성, 종료 시 영구 삭제(폭파)
- 키체인 로그인 과정 없이 디스코드 유저 정보를 가진 커스텀 딥링크(gam://)를 자동 생성합니다.
"""

import os
import sys
import asyncio
import urllib.parse
import aiohttp
import discord
from discord import app_commands
from discord.ext import commands
from aiohttp import web

import zerotier_api

# 봇 기본 설정 (특권 인텐트 없이 기본 인텐트만으로 /합주실개설, /합주실종료 슬래시 명령어 완벽 지원)
intents = discord.Intents.default()

bot = commands.Bot(command_prefix="!", intents=intents)

# 기본 포트 및 세션 관리 (Render.com의 PORT 및 RENDER_EXTERNAL_URL 자동 호환)
DEFAULT_PORT = 9999
HTTP_PORT = int(os.environ.get("PORT") or os.environ.get("HTTP_PORT", "8765"))
RENDER_URL = os.environ.get("RENDER_EXTERNAL_URL")
REDIRECT_BASE = (os.environ.get("REDIRECT_BASE_URL") or RENDER_URL or f"http://localhost:{HTTP_PORT}").rstrip("/")

room_counter = 1
active_rooms = {}  # room_id -> {"networkId": str, "name": str, "hostId": str}


def create_deep_link(
    user_name: str,
    user_id: str,
    room_id: int,
    room_name: str,
    is_host: bool,
    port: int = 9999,
    ip: str = "",
    zt_net: str = ""
) -> str:
    """gam:// 커스텀 URL 스킴 생성"""
    params = {
        "user": user_name,
        "uid": str(user_id),
        "roomId": str(room_id),
        "name": room_name,
        "isHost": "true" if is_host else "false",
        "port": str(port),
    }
    if ip:
        params["ip"] = ip
    if zt_net:
        params["ztNet"] = zt_net

    query_str = urllib.parse.urlencode(params)
    return f"gam://jam?{query_str}"


def get_redirect_url(target_deep_link: str) -> str:
    """디스코드 버튼 및 브라우저 클릭용 HTTP 리다이렉트 URL 반환"""
    quoted = urllib.parse.quote(target_deep_link, safe="")
    return f"{REDIRECT_BASE}/open?target={quoted}"


async def handle_redirect(request: web.Request) -> web.Response:
    """브라우저 요청 시 gam:// 커스텀 스킴을 호출하여 앱을 실행시키는 페이지"""
    target = request.query.get("target") or request.query.get("url")
    if not target or not target.startswith("gam://"):
        return web.Response(text="오류: 유효한 SyncRoom(gam://) 링크가 아닙니다.", status=400)

    html = f"""<!DOCTYPE html>
<html lang="ko">
<head>
  <meta charset="utf-8">
  <title>SyncRoom 합주실 연결</title>
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>
    body {{
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      background: #1e1f22;
      color: #ffffff;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
      margin: 0;
      padding: 20px;
      box-sizing: border-box;
    }}
    .card {{
      background: #2b2d31;
      padding: 32px;
      border-radius: 16px;
      text-align: center;
      max-width: 480px;
      width: 100%;
      box-shadow: 0 12px 32px rgba(0,0,0,0.5);
      border: 1px solid rgba(255,255,255,0.08);
    }}
    .icon {{ font-size: 48px; margin-bottom: 12px; }}
    h1 {{ font-size: 20px; margin: 0 0 8px; color: #5865F2; }}
    p {{ font-size: 14px; color: #949BA4; line-height: 1.6; margin-bottom: 24px; }}
    .btn {{
      display: block;
      background: #5865F2;
      color: white;
      text-decoration: none;
      padding: 14px 20px;
      border-radius: 10px;
      font-weight: bold;
      font-size: 15px;
      transition: 0.2s;
    }}
    .btn:hover {{ background: #4752c4; }}
    .uri-box {{
      margin-top: 20px;
      padding: 10px;
      background: #111214;
      border-radius: 8px;
      font-family: monospace;
      font-size: 11px;
      word-break: break-all;
      color: #b5bac1;
      text-align: left;
    }}
  </style>
</head>
<body>
  <div class="card">
    <div class="icon">🎸</div>
    <h1>SyncRoom 앱으로 연결 중...</h1>
    <p>브라우저 상단에 <strong>[gam 열기]</strong> 또는 <strong>[허용]</strong> 팝업이 나타나면 클릭해주세요.<br>창이 자동으로 열리지 않으면 아래 버튼을 눌러주세요.</p>
    <a href="{target}" class="btn">🚀 SyncRoom 앱 열기</a>
    <div class="uri-box">{target}</div>
  </div>
  <script>
    setTimeout(function() {{
      window.location.href = "{target}";
    }}, 150);
  </script>
</body>
</html>"""
    return web.Response(text=html, content_type="text/html")


async def handle_health(request: web.Request) -> web.Response:
    """Render.com 헬스체크 및 슬립 방지용 엔드포인트"""
    return web.Response(text="SyncRoom Discord Bot is running healthy!", content_type="text/plain")


async def render_keep_alive():
    """Render.com 무료 티어 슬립(15분 비활성) 방지용 백그라운드 핑 태스크"""
    render_url = os.environ.get("RENDER_EXTERNAL_URL")
    if not render_url:
        return
    print(f"🔄 Render.com 24시간 슬립 방지 활성화: {render_url}/healthz")
    while True:
        await asyncio.sleep(600)  # 10분마다 헬스체크 핑
        try:
            async with aiohttp.ClientSession() as session:
                async with session.get(f"{render_url}/healthz", timeout=10) as resp:
                    pass
        except Exception:
            pass


async def setup_hook():
    """디스코드 봇 시작 시 리다이렉트 HTTP 웹서버 동시 가동"""
    try:
        app = web.Application()
        app.router.add_get('/', handle_health)
        app.router.add_get('/healthz', handle_health)
        app.router.add_get('/open', handle_redirect)
        runner = web.AppRunner(app)
        await runner.setup()
        site = web.TCPSite(runner, '0.0.0.0', HTTP_PORT)
        await site.start()
        print(f"🌐 원클릭 리다이렉트 웹 서버 가동: http://0.0.0.0:{HTTP_PORT} (Base: {REDIRECT_BASE})")
    except Exception as e:
        print(f"웹 리다이렉트 서버 가동 알림 (포트 충돌 등): {e}")

    # Render.com 슬립 방지 태스크 시작
    if os.environ.get("RENDER_EXTERNAL_URL"):
        asyncio.create_task(render_keep_alive())

bot.setup_hook = setup_hook


@bot.event
async def on_ready():
    print("=" * 55)
    print(f"🎸 SyncRoom 디스코드 봇 로그인 성공: {bot.user}")
    print(f"OS 환경: {sys.platform} (macOS / Windows 호환)")
    token = zerotier_api.get_api_token()
    if token:
        print("🌐 ZeroTier Central API 연동 활성화: 1회용 가상 회선 자동 생성 준비 완료")
    else:
        print("⚠️ ZeroTier API 토큰 미설정 (.env에 ZEROTIER_API_TOKEN 추가 시 가상 랜 자동 생성)")
    print("=" * 55)
    try:
        synced = await bot.tree.sync()
        print(f"✅ 슬래시 명령어 {len(synced)}개 동기화 완료")
    except Exception as e:
        print(f"슬래시 명령어 동기화 오류: {e}")


class JamRoomView(discord.ui.View):
    """합주실 참여 버튼 뷰 (Discord URL 정책 준수: HTTP 리다이렉트 경유)"""
    def __init__(self, host_link: str, guest_link: str):
        super().__init__(timeout=None)
        self.add_item(discord.ui.Button(
            label="👑 방장으로 앱 실행",
            style=discord.ButtonStyle.link,
            url=get_redirect_url(host_link)
        ))
        self.add_item(discord.ui.Button(
            label="🎧 게스트로 합주실 참가",
            style=discord.ButtonStyle.link,
            url=get_redirect_url(guest_link)
        ))


@bot.tree.command(name="합주실개설", description="1회용 ZeroTier 가상 랜을 자동 생성하고 SyncRoom 앱 직결 링크를 제공합니다.")
@app_commands.describe(
    방이름="합주실 이름 (예: 퇴근길 재즈 잼)",
    공인ip="방장의 공인 IP (선택사항, 미입력 시 ZeroTier P2P 자동 연결)",
    포트="SFU UDP 포트 (기본값: 9999)"
)
async def slash_create_room(
    interaction: discord.Interaction,
    방이름: str = "온라인 실시간 합주실",
    공인ip: str = "",
    포트: int = 9999
):
    await interaction.response.defer()

    global room_counter
    current_room_id = room_counter
    room_counter += 1

    user = interaction.user
    user_name = user.display_name
    user_id = str(user.id)

    # 1. ZeroTier 1회용 가상 회선 자동 생성 시도
    zt_info = await zerotier_api.create_temp_network(f"SyncRoom-Room{current_room_id}-{방이름}")
    zt_net_id = zt_info["networkId"] if zt_info else ""

    # 세션 보관
    active_rooms[current_room_id] = {
        "networkId": zt_net_id,
        "name": 방이름,
        "hostId": user_id,
        "port": 포트,
    }

    host_url = create_deep_link(user_name, user_id, current_room_id, 방이름, is_host=True, port=포트, ip=공인ip, zt_net=zt_net_id)
    guest_url = create_deep_link(user_name, user_id, current_room_id, 방이름, is_host=False, port=포트, ip=공인ip, zt_net=zt_net_id)

    embed = discord.Embed(
        title=f"🎵 {방이름} (방 번호 #{current_room_id})",
        description="**SyncRoom(`gam`) 전용 실시간 무압축 UDP 합주실이 개설되었습니다!**\n"
                    "아래 링크를 누르면 Mac / Windows에 설치된 `gam` 앱이 즉시 실행되며, "
                    "비밀번호 입력이나 키체인 저장 없이 디스코드 프로필로 즉시 입장합니다.",
        color=0x5865F2
    )
    embed.add_field(name="👑 개설자 (방장)", value=user.mention, inline=True)
    embed.add_field(name="🌐 UDP 포트", value=f"`{포트}`", inline=True)

    if zt_net_id:
        embed.add_field(
            name="🛡️ 1회용 ZeroTier 가상 회선 (P2P 자동 직결)",
            value=f"`{zt_net_id}` (공유기 포트포워딩 불필요)",
            inline=False
        )
    elif 공인ip:
        embed.add_field(name="📡 SFU 타깃 IP", value=f"`{공인ip}`", inline=True)

    embed.add_field(
        name="🚀 원클릭 바로가기 링크 (Mac & Windows)",
        value=(
            f"• **[👑 방장으로 앱 실행하기]({get_redirect_url(host_url)})**\n"
            f"• **[🎧 게스트로 합주실 참가하기]({get_redirect_url(guest_url)})**\n\n"
            f"📋 **직접 실행 링크 (브라우저 주소창 또는 Win+R)**:\n"
            f"• 방장: `{host_url}`\n"
            f"• 게스트: `{guest_url}`\n\n"
            f"*※ 합주가 끝나면 `/합주실종료 방번호:{current_room_id}` 명령어로 가상 회선이 완전히 자동 삭제됩니다.*"
        ),
        inline=False
    )
    embed.set_footer(text="SyncRoom Audio Core • ZeroTier P2P 가상 회선 지원")

    try:
        view = JamRoomView(host_url, guest_url)
        await interaction.followup.send(embed=embed, view=view)
    except Exception as e:
        print(f"인터랙션 버튼 전송 실패 (기본 전송): {e}")
        await interaction.followup.send(embed=embed)


@bot.tree.command(name="합주실종료", description="합주실을 닫고 ZeroTier 1회용 가상 회선을 영구 삭제(폭파)합니다.")
@app_commands.describe(방번호="종료할 합주실 방 번호 (숫자)")
async def slash_close_room(interaction: discord.Interaction, 방번호: int):
    room = active_rooms.get(방번호)
    if not room:
        await interaction.response.send_message(
            f"⚠️ 방 번호 `#{방번호}`에 해당하는 활성 합주실 정보를 찾을 수 없습니다.",
            ephemeral=True
        )
        return

    net_id = room.get("networkId")
    deleted = False
    if net_id:
        deleted = await zerotier_api.delete_network(net_id)

    del active_rooms[방번호]

    embed = discord.Embed(
        title=f"🛑 합주실 #{방번호} ({room['name']}) 종료 완료",
        description="**합주실이 안전하게 종료되었습니다.**\n"
                    "참여자들의 컴퓨터에서 가상 랜 인터페이스가 해제되며 원래 네트워크로 복귀합니다.",
        color=0xED4245
    )
    if net_id:
        status_text = "영구 삭제(폭파) 완료" if deleted else "삭제 실패 (수동 확인 필요)"
        embed.add_field(name="🛡️ ZeroTier 가상 회선", value=f"`{net_id}` : {status_text}", inline=False)

    await interaction.response.send_message(embed=embed)


# 텍스트 프리픽스 명령어 지원: !합주실 [방이름]
@bot.command(name="합주실", aliases=["jam", "합주"])
async def cmd_create_room(ctx, *, 방이름: str = "온라인 실시간 합주실"):
    global room_counter
    current_room_id = room_counter
    room_counter += 1

    user = ctx.author
    user_name = user.display_name
    user_id = str(user.id)

    zt_info = await zerotier_api.create_temp_network(f"SyncRoom-Room{current_room_id}-{방이름}")
    zt_net_id = zt_info["networkId"] if zt_info else ""

    active_rooms[current_room_id] = {
        "networkId": zt_net_id,
        "name": 방이름,
        "hostId": user_id,
        "port": DEFAULT_PORT,
    }

    host_url = create_deep_link(user_name, user_id, current_room_id, 방이름, is_host=True, port=DEFAULT_PORT, zt_net=zt_net_id)
    guest_url = create_deep_link(user_name, user_id, current_room_id, 방이름, is_host=False, port=DEFAULT_PORT, zt_net=zt_net_id)

    embed = discord.Embed(
        title=f"🎵 {방이름} (방 번호 #{current_room_id})",
        description="**SyncRoom(`gam`) 전용 합주실이 개설되었습니다!**\n"
                    "아래 링크를 누르면 Mac / Windows의 `gam` 앱이 로그인 없이 즉시 열립니다.",
        color=0x23A55A
    )
    embed.add_field(name="👑 개설자", value=user.mention, inline=True)
    if zt_net_id:
        embed.add_field(name="🛡️ ZeroTier 가상 회선", value=f"`{zt_net_id}`", inline=True)
    embed.add_field(
        name="🔗 다이렉트 실행 링크",
        value=(
            f"• **[👑 방장으로 앱 실행하기]({get_redirect_url(host_url)})**\n"
            f"• **[🎧 게스트로 합주실 참가하기]({get_redirect_url(guest_url)})**\n\n"
            f"📋 **직접 실행 링크 (브라우저 주소창 또는 Win+R)**:\n"
            f"• 방장: `{host_url}`\n"
            f"• 게스트: `{guest_url}`\n\n"
            f"*종료 시 `!종료 {current_room_id}` 입력*"
        ),
        inline=False
    )
    try:
        view = JamRoomView(host_url, guest_url)
        await ctx.send(embed=embed, view=view)
    except Exception:
        await ctx.send(embed=embed)


@bot.command(name="종료", aliases=["close", "합주종료"])
async def cmd_close_room(ctx, 방번호: int):
    room = active_rooms.get(방번호)
    if not room:
        await ctx.send(f"⚠️ 방 번호 `#{방번호}` 합주실을 찾을 수 없습니다.")
        return

    net_id = room.get("networkId")
    if net_id:
        await zerotier_api.delete_network(net_id)
    del active_rooms[방번호]

    await ctx.send(f"🛑 합주실 `#{방번호}` 및 ZeroTier 가상 회선(`{net_id}`)이 완전히 삭제되었습니다.")


def main():
    token = os.environ.get("DISCORD_BOT_TOKEN")
    if not token:
        if os.path.exists(".env"):
            with open(".env", "r", encoding="utf-8") as f:
                for line in f:
                    if line.startswith("DISCORD_BOT_TOKEN="):
                        token = line.strip().split("=", 1)[1].strip().strip('"').strip("'")
                        break

    if not token or token == "YOUR_DISCORD_BOT_TOKEN_HERE":
        print("[!] 오류: DISCORD_BOT_TOKEN 환경변수 또는 .env 파일에 봇 토큰이 지정되지 않았습니다.")
        print("사용법:")
        print("  macOS / Linux: export DISCORD_BOT_TOKEN='내_봇_토큰' && python3 bot.py")
        print("  Windows:       set DISCORD_BOT_TOKEN=내_봇_토큰 && python bot.py")
        sys.exit(1)

    bot.run(token)


if __name__ == "__main__":
    main()
