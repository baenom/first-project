"""
ZeroTier Central API 연동 모듈
- 1회용 임시 가상 네트워크 생성 및 영구 삭제 지원
- ZeroTier Basic 플랜(무료)으로 무제한 네트워크 생성 가능
"""

import os
import aiohttp
from typing import Optional, Dict, Any

ZEROTIER_BASE_URL = "https://api.zerotier.com/api/v1"


def get_api_token() -> str:
    """환경변수 또는 .env 파일에서 ZEROTIER_API_TOKEN 조회"""
    token = os.environ.get("ZEROTIER_API_TOKEN", "")
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
                        if line.startswith("ZEROTIER_API_TOKEN="):
                            token = line.strip().split("=", 1)[1].strip().strip('"').strip("'")
                            if token:
                                return token
    return token


def get_auth_header(token: str) -> str:
    """ZeroTier API 인증 헤더 생성 (JWT 토큰일 경우 Bearer, 레거시 키일 경우 token)"""
    return f"Bearer {token}" if token.startswith("ey") else f"token {token}"


async def create_temp_network(name: str = "SyncRoom-Jam") -> Optional[Dict[str, Any]]:
    """
    ZeroTier Central API를 호출하여 즉시 연결 가능한 1회용 네트워크 생성
    - private: False 설정으로 관리자 승인 없이 누구나 16자리 ID로 즉시 연결 허용
    - 10.147.20.0/24 가상 IP 자동 할당 풀 구성
    """
    token = get_api_token()
    if not token:
        print("[ZeroTier] ZEROTIER_API_TOKEN이 설정되지 않아 가상 네트워크 자동 생성을 건너뜁니다.")
        return None

    headers = {
        "Authorization": get_auth_header(token),
        "Content-Type": "application/json",
    }

    payload = {
        "config": {
            "name": name,
            "private": False,  # 승인 대기 없이 즉시 통신 허용
            "ipAssignmentPools": [
                {
                    "ipRangeStart": "10.147.20.1",
                    "ipRangeEnd": "10.147.20.254"
                }
            ],
            "routes": [
                {
                    "target": "10.147.20.0/24"
                }
            ],
            "v4AssignMode": {
                "zt": True
            }
        }
    }

    try:
        async with aiohttp.ClientSession() as session:
            async with session.post(f"{ZEROTIER_BASE_URL}/network", headers=headers, json=payload) as resp:
                if resp.status in (200, 201):
                    data = await resp.json()
                    network_id = data.get("id")
                    print(f"[ZeroTier] 1회용 임시 네트워크 생성 성공: {network_id} ({name})")
                    return {
                        "networkId": network_id,
                        "name": name,
                        "subnet": "10.147.20.0/24",
                        "raw": data
                    }
                else:
                    err_text = await resp.text()
                    print(f"[ZeroTier] 네트워크 생성 실패 (Status {resp.status}): {err_text}")
                    return None
    except Exception as e:
        print(f"[ZeroTier] API 요청 오류: {e}")
        return None


async def delete_network(network_id: str) -> bool:
    """
    합주 종료 시 ZeroTier Central에서 네트워크를 영구 삭제(폭파)
    """
    token = get_api_token()
    if not token or not network_id:
        return False

    headers = {
        "Authorization": get_auth_header(token),
    }

    try:
        async with aiohttp.ClientSession() as session:
            async with session.delete(f"{ZEROTIER_BASE_URL}/network/{network_id}", headers=headers) as resp:
                if resp.status in (200, 204):
                    print(f"[ZeroTier] 가상 네트워크 영구 삭제 완료: {network_id}")
                    return True
                else:
                    err_text = await resp.text()
                    print(f"[ZeroTier] 네트워크 삭제 실패 ({resp.status}): {err_text}")
                    return False
    except Exception as e:
        print(f"[ZeroTier] 네트워크 삭제 오류: {e}")
        return False
