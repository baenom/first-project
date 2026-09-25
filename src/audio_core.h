#ifndef AUDIO_CORE_H
#define AUDIO_CORE_H

#include <cstdint>

#ifdef _WIN32
    #define EXPORT __declspec(dllexport)
#else
    #define EXPORT __attribute__((visibility("default")))
#endif

extern "C" {
    // 오디오 엔진 초기화 (샘플레이트: 48000, 버퍼 사이즈: 64, 128, 256)
    EXPORT int init_audio_engine(int sample_rate, int buffer_size);

    // 내 로컬 UDP 바인딩 포트 설정 (start_audio_stream 호출 전 설정 가능, 기본: 9999)
    EXPORT void set_local_port(int port);

    // 내 유저 ID 및 방 ID 설정
    EXPORT void set_my_identity(int room_id, int user_id);

    // P2P (오각별 Mesh) 피어 등록/갱신 (user_id: 상대방 식별자, ip: 상대방 공인/사설 IP, port: 상대방 UDP 포트)
    EXPORT void add_p2p_peer(int user_id, const char* ip, int port);

    // P2P 피어 제거
    EXPORT void remove_p2p_peer(int user_id);

    // 등록된 모든 P2P 피어 초기화
    EXPORT void clear_p2p_peers();

    // 현재 등록된 활성 P2P 피어 수 조회
    EXPORT int get_p2p_peer_count();

    // 특정 피어와의 P2P RTT(핑 지연시간 ms) 조회
    EXPORT float get_p2p_peer_rtt(int user_id);

    // [하위 호환성 유지] 기존 SFU 엔드포인트 설정 (내부적으로 P2P 피어로 자동 등록)
    EXPORT void set_sfu_endpoint(const char* ip, int port, int room_id, int user_id);

    // 오디오 스트림(오인페 캡처 -> P2P 다중 송신 / 수신 -> 멀티채널 믹싱 -> 오인페 재생) 시작
    EXPORT void start_audio_stream();

    // 오디오 스트림 중지
    EXPORT void stop_audio_stream();

    // 참여자별 개별 볼륨 조절 (user_id: 상대방 ID, volume: 0.0 ~ 2.0)
    EXPORT void set_channel_volume(int user_id, float volume);

    // 내 오인페 마이크/악기 입력 게인 조절 (gain: 0.0 ~ 2.0)
    EXPORT void set_input_gain(float gain);

    // 오디오 실시간 지표 (대표 RTT 핑 ms, 입력 레벨 0~1, 출력 레벨 0~1) 조회
    EXPORT void get_audio_stats(float* out_rtt_ms, float* out_in_level, float* out_out_level);

    // 네트워크 실시간 패킷 지표 (송신 패킷수, 수신 패킷수, 활성 원격 피어수) 조회
    EXPORT void get_network_stats(uint32_t* out_tx_packets, uint32_t* out_rx_packets, int* out_active_remote_peers);

    // 현재 오디오 스트림 실행 여부 확인 (1: 실행중, 0: 중지됨)
    EXPORT int is_audio_running();

    // 내장 SFU 릴레이 서버 시작 (하위 호환 및 하이브리드 지원)
    EXPORT int start_embedded_sfu(int port);

    // 내장 SFU 릴레이 서버 중지
    EXPORT void stop_embedded_sfu();

    // 내장 SFU 서버 가동 상태 확인
    EXPORT int is_sfu_running();

    // 현재 SFU 중계 서버에 연결된 활성 피어 수 조회
    EXPORT int get_sfu_peer_count();
}

#endif // AUDIO_CORE_H