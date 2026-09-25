#ifndef SYNCROOM_PROTOCOL_H
#define SYNCROOM_PROTOCOL_H

#include <cstdint>

#pragma pack(push, 1)

// 매직 넘버: 'S' 'Y' 'N' 'C' (0x53594E43)
constexpr uint32_t SYNC_MAGIC = 0x53594E43;

enum PacketType : uint8_t {
    PACKET_TYPE_JOIN      = 1, // 방 참가 등록
    PACKET_TYPE_LEAVE     = 2, // 방 퇴장
    PACKET_TYPE_AUDIO     = 3, // 실시간 무압축 PCM 오디오 데이터
    PACKET_TYPE_PING      = 4, // RTT 지연시간 측정용 핑
    PACKET_TYPE_PONG      = 5, // 핑 응답
    PACKET_TYPE_HEARTBEAT = 6, // 세션 유지용 킵얼라이브
};

struct AudioPacketHeader {
    uint32_t magic;           // SYNC_MAGIC 확인용
    uint8_t  packet_type;     // PacketType enum
    uint16_t room_id;         // 방 번호 (기본 1)
    uint16_t user_id;         // 유저 식별자 ID
    uint32_t sequence_num;    // 시퀀스 번호 (지터 버퍼 & 패킷 손실률 계산)
    uint64_t timestamp_us;    // 마이크로초 타임스탬프 (RTT 계산용)
    uint16_t sample_rate;     // 샘플레이트 (기본 48000Hz)
    uint8_t  channels;        // 채널 수 (1: 모노, 2: 스테레오)
    uint8_t  bits_per_sample; // 비트 심도 (16: int16_t PCM, 32: float)
    uint16_t frame_count;     // 버퍼 프레임 수 (64, 128, 256)
    uint16_t payload_bytes;   // 헤더 뒤에 붙는 오디오 원시 데이터 바이트 수
};

#pragma pack(pop)

#endif // SYNCROOM_PROTOCOL_H
