"""
Tailscale API v2 연동 모듈
- 1회용 임시 Auth Key 생성 및 서울 DERP(초저지연 국내 릴레이) 연동 지원
- Tailscale Free 플랜으로 최대 3개 사용자 및 100개 기기 지원
"""

import os
import aiohttp
from typing import Optional, Dict, Any, List

TAILSCALE_BASE_URL = "https://api.tailscale.com/api/v2"


def get_api_key() -> str:
    """환경변수 또는 .env 파일에서 TAILSCALE_API_KEY 조회"""
    token = os.environ.get("TAILSCALE_API_KEY", "") or os.environ.get("TAILSCALE_AUTH_KEY", "")
    if not token:
        candidates = [
            ".env",
            os.path.join(os.path.dirname(__file__), ".env"),
            os.path.join(os.path.dirname(os.path.dirname(__file__)), ".env"),
        ]
        for env_path in candidates:
            if os.path.exists(env_path):
                with open(env_path, "r", encoding="utf-8") as f:
                    for line in f:
                        if line.startswith("TAILSCALE_API_KEY=") or line.startswith("TAILSCALE_AUTH_KEY="):
                            token = line.strip().split("=", 1)[1].strip().strip('"').strip("'")
                            if token:
                                return token
    return token


def get_tailnet() -> str:
    """사용자 Tailnet 조직명 조회 (기본값: '-' 현재 인증된 기본 tailnet)"""
    return os.environ.get("TAILSCALE_TAILNET", "-").strip()


async def create_temp_auth_key(name: str = "SyncRoom-Jam") -> Optional[Dict[str, Any]]:
    """
    Tailscale API를 호출하여 즉시 연결 가능한 1회용 임시 Auth Key 생성
    - ephemeral: True 설정으로 합주 종료 시 노드가 Tailnet에서 자동 삭제
    - preauthorized: True 설정으로 관리자 승인 없이 즉시 가상 IP(100.x.x.x) 부여
    - 대한민국 서울 DERP-9 (sel) 릴레이 지원으로 초저지연(10~20ms) 보장
    """
    api_key = get_api_key()
    if not api_key:
        print("[Tailscale] TAILSCALE_API_KEY가 설정되지 않아 가상 회선 키 자동 생성을 건너뜁니다.")
        return None

    tailnet = get_tailnet()
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }

    # 기본 Ephemeral 키 페이로드
    payload = {
        "capabilities": {
            "devices": {
                "create": {
                    "reusable": True,
                    "ephemeral": True,
                    "preauthorized": True
                }
            }
        },
        "expirySeconds": 86400,
        "description": f"SyncRoom 1회용 합주실 ({name})"
    }

    url = f"{TAILSCALE_BASE_URL}/tailnet/{tailnet}/keys"

    try:
        async with aiohttp.ClientSession() as session:
            async with session.post(url, headers=headers, json=payload) as resp:
                if resp.status in (200, 201):
                    data = await resp.json()
                    auth_key = data.get("key")
                    key_id = data.get("id")
                    print(f"[Tailscale] 1회용 임시 Auth Key 생성 성공: {key_id} ({name})")
                    return {
                        "key": auth_key,
                        "keyId": key_id,
                        "name": name,
                        "tailnet": tailnet,
                        "raw": data
                    }
                else:
                    err_text = await resp.text()
                    print(f"[Tailscale] Auth Key 생성 실패 (Status {resp.status}): {err_text}")
                    return None
    except Exception as e:
        print(f"[Tailscale] API 요청 오류: {e}")
        return None


async def delete_auth_key(key_id: str) -> bool:
    """합주 종료 시 생성된 Auth Key 파기"""
    api_key = get_api_key()
    if not api_key or not key_id:
        return False

    tailnet = get_tailnet()
    headers = {
        "Authorization": f"Bearer {api_key}",
    }

    url = f"{TAILSCALE_BASE_URL}/tailnet/{tailnet}/keys/{key_id}"

    try:
        async with aiohttp.ClientSession() as session:
            async with session.delete(url, headers=headers) as resp:
                if resp.status in (200, 204):
                    print(f"[Tailscale] Auth Key 삭제 완료: {key_id}")
                    return True
                else:
                    return False
    except Exception as e:
        print(f"[Tailscale] Auth Key 삭제 오류: {e}")
        return False


async def get_tailnet_devices() -> List[Dict[str, Any]]:
    """현재 Tailnet의 활성 디바이스 및 100.x.x.x 가상 IP 목록 조회"""
    api_key = get_api_key()
    if not api_key:
        return []

    tailnet = get_tailnet()
    headers = {
        "Authorization": f"Bearer {api_key}",
    }

    url = f"{TAILSCALE_BASE_URL}/tailnet/{tailnet}/devices"

    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(url, headers=headers) as resp:
                if resp.status == 200:
                    data = await resp.json()
                    return data.get("devices", [])
                return []
    except Exception as e:
        print(f"[Tailscale] 디바이스 목록 조회 오류: {e}")
        return []
