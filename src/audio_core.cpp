#ifdef _WIN32
    #ifndef WIN32_LEAN_AND_MEAN
        #define WIN32_LEAN_AND_MEAN
    #endif
    #ifndef NOMINMAX
        #define NOMINMAX
    #endif
    #include <winsock2.h>
    #include <ws2tcpip.h>
    #include <windows.h>
    #pragma comment(lib, "ws2_32.lib")
    typedef int socklen_t;
#else
    #include <sys/socket.h>
    #include <netinet/in.h>
    #include <arpa/inet.h>
    #include <unistd.h>
    #include <fcntl.h>
    #define INVALID_SOCKET -1
    #define SOCKET_ERROR   -1
    #define closesocket    close
    typedef int SOCKET;
#endif

#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

#include <iostream>
#include <vector>
#include <unordered_map>
#include <chrono>
#include <cstring>
#include <atomic>
#include <thread>
#include <mutex>
#include <cmath>
#include <algorithm>
#include <deque>
#include <memory>

#include "audio_core.h"
#include "protocol.h"

namespace {
    // 엔진 상태
    std::atomic<bool> g_initialized{false};
    std::atomic<bool> g_running{false};
    int g_sample_rate = 48000;
    int g_buffer_size = 128; // 프레임 단위 (128 samples = 2.67ms @ 48kHz)

    // 로컬 바인딩 및 내 식별 정보
    int g_local_port = 9999;
    uint16_t g_room_id = 1;
    uint16_t g_user_id = 101;

    // 볼륨 및 레벨
    std::atomic<float> g_input_gain{1.0f};
    std::atomic<float> g_in_level{0.0f};
    std::atomic<float> g_out_level{0.0f};
    std::atomic<float> g_current_rtt_ms{0.0f};

    // 네트워크 진단 지표
    std::atomic<uint32_t> g_tx_packets{0};
    std::atomic<uint32_t> g_rx_packets{0};
    std::atomic<uint32_t> g_sequence_counter{0};

    // P2P 피어 정보 구조체 (오각별 Full-Mesh 통신용)
    struct PeerEndpoint {
        uint16_t user_id{0};
        std::string ip;
        int port{0};
        sockaddr_in addr{};
        std::atomic<float> rtt_ms{0.0f};
        std::atomic<uint64_t> last_seen_us{0};
        std::atomic<uint32_t> rx_packets{0};
        std::atomic<float> volume{1.0f};

        // 피어별 독립 지터 버퍼 (다자간 동시 믹싱을 위한 독립 큐)
        std::mutex queue_mutex;
        std::deque<int16_t> audio_queue;
        int16_t last_sample_L{0};
        int16_t last_sample_R{0};
        bool was_starving{false};
    };

    // 등록된 모든 P2P 피어 맵 (User ID -> PeerEndpoint)
    std::mutex g_peers_mutex;
    std::unordered_map<uint16_t, std::shared_ptr<PeerEndpoint>> g_peers;

    // 네트워크 소켓 및 스레드
    SOCKET g_sockfd = INVALID_SOCKET;
    std::mutex g_socket_send_mutex;
    std::thread g_network_thread;
    std::thread g_ping_thread;

    // 하드웨어 오디오 디바이스 (miniaudio)
    ma_device g_ma_device;
    std::atomic<bool> g_ma_device_initialized{false};
    std::atomic<bool> g_hardware_callback_active{false};
    std::atomic<bool> g_fallback_tx_running{false};
    std::thread g_fallback_tx_thread;

    // 아날로그 새츄레이션 기반 부드러운 소프트 리미터:
    // 정상 레벨(-1.9 dBFS 이하)에서는 100% 무손실 선형 유지,
    // 초과 시 tanh 기반의 아날로그 포화 곡선으로 라운딩하여 "지지직" 디지털 클리핑 왜곡 차단
    inline int16_t soft_clip(float x) {
        const float threshold = 26214.0f; // -1.9 dBFS
        const float max_val = 32767.0f;
        if (x > threshold) {
            float excess = x - threshold;
            float compressed = threshold + (max_val - threshold) * std::tanh(excess / (max_val - threshold));
            return static_cast<int16_t>(compressed > max_val ? max_val : compressed);
        } else if (x < -threshold) {
            float excess = -x - threshold;
            float compressed = -(threshold + (32768.0f - threshold) * std::tanh(excess / (32768.0f - threshold)));
            return static_cast<int16_t>(compressed < -32768.0f ? -32768.0f : compressed);
        }
        return static_cast<int16_t>(x);
    }
    inline int16_t soft_clip_s16(float sample) { return soft_clip(sample); }

    uint64_t get_time_us() {
        return std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::steady_clock::now().time_since_epoch()
        ).count();
    }

    // miniaudio Duplex 콜백 (마이크 입력 -> P2P 다중 전송 / 수신 피어들 믹싱 -> 스피커 출력)
    void audio_data_callback(ma_device* pDevice, void* pOutput, const void* pInput, ma_uint32 frameCount) {
        g_hardware_callback_active.store(true);

        ma_uint32 cap_channels = (pDevice->capture.channels > 0) ? pDevice->capture.channels : 1;
        ma_uint32 play_channels = (pDevice->playback.channels > 0) ? pDevice->playback.channels : 2;
        ma_uint32 play_samples = frameCount * play_channels;

        // 1. 마이크 입력 캡처 및 등록된 모든 P2P 피어에게 멀티유니캐스트 송신
        if (g_running.load() && pInput != nullptr) {
            ma_uint32 net_channels = 2; // 패킷은 항상 2채널 스테레오로 통일하여 전송
            ma_uint32 net_samples = frameCount * net_channels;
            std::vector<int16_t> processed_pcm(net_samples, 0);

            const int16_t* in_pcm = reinterpret_cast<const int16_t*>(pInput);
            float gain = g_input_gain.load();
            double sum_sq = 0.0;

            for (ma_uint32 f = 0; f < frameCount; ++f) {
                if (cap_channels == 1) {
                    // 모노 마이크 입력을 좌/우 채널로 복제 (칩멍크 왜곡 및 위상 반전 해결)
                    float sample = in_pcm[f] * gain;
                    int16_t s_int = soft_clip(sample);
                    processed_pcm[f * 2] = s_int;
                    processed_pcm[f * 2 + 1] = s_int;

                    float norm = s_int / 32768.0f;
                    sum_sq += (norm * norm);
                } else {
                    // 스테레오 입력
                    float sample_L = in_pcm[f * cap_channels] * gain;
                    float sample_R = in_pcm[f * cap_channels + 1] * gain;
                    int16_t s_L = soft_clip_s16(sample_L);
                    int16_t s_R = soft_clip_s16(sample_R);
                    processed_pcm[f * 2] = s_L;
                    processed_pcm[f * 2 + 1] = s_R;

                    float norm_L = s_L / 32768.0f;
                    float norm_R = s_R / 32768.0f;
                    sum_sq += 0.5 * (norm_L * norm_L + norm_R * norm_R);
                }
            }

            // 마이크 RMS 입력 레벨 계산
            float rms = std::sqrt(sum_sq / (frameCount > 0 ? frameCount : 1));
            float target_level = std::clamp(rms * 4.5f, 0.0f, 1.0f);
            float current = g_in_level.load();
            if (target_level > current) {
                g_in_level.store(target_level);
            } else {
                g_in_level.store(current * 0.82f + target_level * 0.18f);
            }

            // P2P 오디오 패킷 생성
            if (g_sockfd != INVALID_SOCKET) {
                AudioPacketHeader audio_header{};
                audio_header.magic = SYNC_MAGIC;
                audio_header.packet_type = PACKET_TYPE_AUDIO;
                audio_header.room_id = g_room_id;
                audio_header.user_id = g_user_id;
                audio_header.sequence_num = ++g_sequence_counter;
                audio_header.timestamp_us = get_time_us();
                audio_header.sample_rate = static_cast<uint16_t>(g_sample_rate);
                audio_header.channels = static_cast<uint8_t>(net_channels);
                audio_header.bits_per_sample = 16;
                audio_header.frame_count = static_cast<uint16_t>(frameCount);
                audio_header.payload_bytes = static_cast<uint16_t>(net_samples * sizeof(int16_t));

                std::vector<uint8_t> packet(sizeof(AudioPacketHeader) + audio_header.payload_bytes);
                std::memcpy(packet.data(), &audio_header, sizeof(AudioPacketHeader));
                std::memcpy(packet.data() + sizeof(AudioPacketHeader), processed_pcm.data(), audio_header.payload_bytes);

                // 오각별(Full Mesh) P2P: 등록된 모든 상대방 피어들에게 각각 직접 송신
                std::vector<sockaddr_in> target_addrs;
                {
                    std::lock_guard<std::mutex> p_lock(g_peers_mutex);
                    for (const auto& kv : g_peers) {
                        target_addrs.push_back(kv.second->addr);
                    }
                }

                if (!target_addrs.empty()) {
                    std::lock_guard<std::mutex> sock_lock(g_socket_send_mutex);
                    for (const auto& target_addr : target_addrs) {
                        sendto(g_sockfd, (const char*)packet.data(), static_cast<int>(packet.size()), 0,
                               (struct sockaddr*)&target_addr, sizeof(target_addr));
                    }
                    g_tx_packets += static_cast<uint32_t>(target_addrs.size());
                }
            }
        } else if (g_running.load() && pInput == nullptr && pOutput == nullptr) {
            g_in_level.store(g_in_level.load() * 0.75f);
        }

        // 2. 스피커 출력 처리: 모든 수신 피어들의 오디오를 실시간 믹싱 (N-way Audio Mixer)
        if (pOutput != nullptr) {
            int16_t* out_pcm = reinterpret_cast<int16_t*>(pOutput);
            std::memset(out_pcm, 0, play_samples * sizeof(int16_t));

            if (g_running.load()) {
                // 활성 피어 목록 스냅샷 복사 (락 최소화)
                std::vector<std::shared_ptr<PeerEndpoint>> active_peers;
                {
                    std::lock_guard<std::mutex> p_lock(g_peers_mutex);
                    for (const auto& kv : g_peers) {
                        active_peers.push_back(kv.second);
                    }
                }

                constexpr size_t MAX_SAFE_QUEUE = 4800; // ~50ms @ 48kHz stereo (지연 상한선)

                // 각 출력 프레임(L, R 스테레오) 단위로 모든 피어의 샘플을 볼륨 가중 합산
                for (ma_uint32 f = 0; f < frameCount; ++f) {
                    float mixed_L = 0.0f;
                    float mixed_R = 0.0f;

                    for (auto& peer : active_peers) {
                        std::lock_guard<std::mutex> q_lock(peer->queue_mutex);
                        float vol = peer->volume.load();

                        // 과도한 지연 적체 시 버퍼 정리
                        while (peer->audio_queue.size() > MAX_SAFE_QUEUE && peer->audio_queue.size() >= 2) {
                            peer->audio_queue.pop_front();
                            peer->audio_queue.pop_front();
                        }

                        if (peer->audio_queue.size() >= 2) {
                            int16_t s_L = peer->audio_queue.front(); peer->audio_queue.pop_front();
                            int16_t s_R = peer->audio_queue.front(); peer->audio_queue.pop_front();

                            // 직전 언더런 발생 후 패킷 복귀 시 첫 4샘플 소프트 페이드인
                            if (peer->was_starving) {
                                s_L = static_cast<int16_t>(s_L * 0.4f);
                                s_R = static_cast<int16_t>(s_R * 0.4f);
                                peer->was_starving = false;
                            }

                            peer->last_sample_L = s_L;
                            peer->last_sample_R = s_R;

                            mixed_L += (s_L * vol);
                            mixed_R += (s_R * vol);
                        } else {
                            // 피어 버퍼 언더런 발생 시 지수 감쇄(Exponential Decay)로 부드러운 무음 수렴
                            peer->was_starving = true;
                            peer->last_sample_L = static_cast<int16_t>(peer->last_sample_L * 0.82f);
                            peer->last_sample_R = static_cast<int16_t>(peer->last_sample_R * 0.82f);
                            mixed_L += (peer->last_sample_L * vol);
                            mixed_R += (peer->last_sample_R * vol);
                        }
                    }

                    // 아날로그 새츄레이션 소프트 리미터 적용 (디지털 클리핑/사각파 방지)
                    out_pcm[f * 2] = soft_clip(mixed_L);
                    out_pcm[f * 2 + 1] = soft_clip(mixed_R);
                }

                // 출력 RMS 레벨 계산
                double out_sum_sq = 0.0;
                for (ma_uint32 i = 0; i < play_samples; ++i) {
                    float s = out_pcm[i] / 32768.0f;
                    out_sum_sq += (s * s);
                }
                float out_rms = std::sqrt(out_sum_sq / (play_samples > 0 ? play_samples : 1));
                float target_out = std::clamp(out_rms * 4.5f, 0.0f, 1.0f);
                float cur_out = g_out_level.load();
                if (target_out > cur_out) {
                    g_out_level.store(target_out);
                } else {
                    g_out_level.store(cur_out * 0.82f + target_out * 0.18f);
                }
            } else {
                g_out_level.store(0.0f);
            }
        }
    }
}

// 백그라운드 UDP 패킷 수신 루프 (P2P Mesh 패킷 수신 및 피어별 라우팅)
void network_receive_loop() {
    uint8_t buffer[8192];
    sockaddr_in from_addr{};
    socklen_t from_len = sizeof(from_addr);

    while (g_running.load()) {
        int bytes = recvfrom(g_sockfd, (char*)buffer, sizeof(buffer), 0,
                             (struct sockaddr*)&from_addr, &from_len);

        if (bytes >= (int)sizeof(AudioPacketHeader)) {
            auto* header = reinterpret_cast<AudioPacketHeader*>(buffer);
            if (header->magic == SYNC_MAGIC) {
                // 나 자신의 에코 패킷은 무시
                if (header->user_id == g_user_id) continue;

                uint16_t sender_id = header->user_id;
                uint64_t now_us = get_time_us();

                // 해당 피어 찾기 또는 NAT 동적 엔드포인트 학습
                std::shared_ptr<PeerEndpoint> peer;
                {
                    std::lock_guard<std::mutex> lock(g_peers_mutex);
                    auto it = g_peers.find(sender_id);
                    if (it != g_peers.end()) {
                        peer = it->second;
                        // 만약 NAT/공유기로 인해 상대방의 송신 포트가 매핑 변경되어 들어왔다면 주소 자동 갱신
                        if (peer->addr.sin_addr.s_addr != from_addr.sin_addr.s_addr ||
                            peer->addr.sin_port != from_addr.sin_port) {
                            peer->addr = from_addr;
                            char ip_str[INET_ADDRSTRLEN];
                            inet_ntop(AF_INET, &(from_addr.sin_addr), ip_str, INET_ADDRSTRLEN);
                            peer->ip = ip_str;
                            peer->port = ntohs(from_addr.sin_port);
                        }
                    } else {
                        // 사전에 등록되지 않은 피어로부터 첫 패킷 수신 시 동적 피어 자동 등록 (홀펀칭 자동 적응)
                        peer = std::make_shared<PeerEndpoint>();
                        peer->user_id = sender_id;
                        peer->addr = from_addr;
                        char ip_str[INET_ADDRSTRLEN];
                        inet_ntop(AF_INET, &(from_addr.sin_addr), ip_str, INET_ADDRSTRLEN);
                        peer->ip = ip_str;
                        peer->port = ntohs(from_addr.sin_port);
                        peer->last_seen_us.store(now_us);
                        g_peers[sender_id] = peer;
                        std::cout << "[AudioCore P2P] Dynamically discovered peer: User " 
                                  << sender_id << " (" << peer->ip << ":" << peer->port << ")" << std::endl;
                    }
                }

                if (peer) {
                    peer->last_seen_us.store(now_us);

                    if (header->packet_type == PACKET_TYPE_PING) {
                        // 상대방의 핑에 대해 즉시 퐁(PONG) 응답 반사
                        AudioPacketHeader pong_header = *header;
                        pong_header.packet_type = PACKET_TYPE_PONG;
                        pong_header.user_id = g_user_id;

                        std::lock_guard<std::mutex> sock_lock(g_socket_send_mutex);
                        sendto(g_sockfd, (const char*)&pong_header, sizeof(pong_header), 0,
                               (struct sockaddr*)&from_addr, sizeof(from_addr));
                        g_tx_packets++;
                    } else if (header->packet_type == PACKET_TYPE_PONG) {
                        // 핑 응답 도착: RTT 계산
                        if (now_us > header->timestamp_us) {
                            float rtt = (now_us - header->timestamp_us) / 1000.0f;
                            peer->rtt_ms.store(rtt);
                            g_current_rtt_ms.store(rtt);
                        }
                    } else if (header->packet_type == PACKET_TYPE_HEARTBEAT) {
                        // 홀펀칭 킵얼라이브 확인
                        peer->last_seen_us.store(now_us);
                    } else if (header->packet_type == PACKET_TYPE_AUDIO) {
                        peer->rx_packets++;
                        g_rx_packets++;

                        int samples = header->payload_bytes / sizeof(int16_t);
                        const int16_t* pcm = reinterpret_cast<const int16_t*>(buffer + sizeof(AudioPacketHeader));

                        // 해당 피어의 독립 지터 큐에 오디오 데이터 추가
                        std::lock_guard<std::mutex> q_lock(peer->queue_mutex);
                        if (header->channels == 1) {
                            for (int i = 0; i < samples; ++i) {
                                peer->audio_queue.push_back(pcm[i]);
                                peer->audio_queue.push_back(pcm[i]);
                            }
                        } else {
                            for (int i = 0; i < samples; ++i) {
                                peer->audio_queue.push_back(pcm[i]);
                            }
                        }

                        // 수신 큐 비상 상한선 유지 (~60ms 분량)
                        constexpr size_t EMERGENCY_MAX_QUEUE = 5760;
                        while (peer->audio_queue.size() > EMERGENCY_MAX_QUEUE && peer->audio_queue.size() >= 2) {
                            peer->audio_queue.pop_front();
                            peer->audio_queue.pop_front();
                        }
                    } else if (header->packet_type == PACKET_TYPE_LEAVE) {
                        // 피어 퇴장
                        std::lock_guard<std::mutex> lock(g_peers_mutex);
                        g_peers.erase(sender_id);
                        std::cout << "[AudioCore P2P] Peer left: User " << sender_id << std::endl;
                    }
                }
            }
        }
    }
}

// 하드웨어 오디오 콜백이 대기 중일 때 동작하는 백업 무음 패킷 송신 루프 (홀펀칭 및 세션 개방용)
void fallback_silence_tx_loop() {
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    
    while (g_running.load() && g_fallback_tx_running.load()) {
        if (!g_hardware_callback_active.load() && g_sockfd != INVALID_SOCKET) {
            ma_uint32 channels = 2;
            ma_uint32 total_samples = static_cast<ma_uint32>(g_buffer_size * channels);
            std::vector<int16_t> silence_pcm(total_samples, 0);

            AudioPacketHeader audio_header{};
            audio_header.magic = SYNC_MAGIC;
            audio_header.packet_type = PACKET_TYPE_AUDIO;
            audio_header.room_id = g_room_id;
            audio_header.user_id = g_user_id;
            audio_header.sequence_num = ++g_sequence_counter;
            audio_header.timestamp_us = get_time_us();
            audio_header.sample_rate = static_cast<uint16_t>(g_sample_rate);
            audio_header.channels = static_cast<uint8_t>(channels);
            audio_header.bits_per_sample = 16;
            audio_header.frame_count = static_cast<uint16_t>(g_buffer_size);
            audio_header.payload_bytes = static_cast<uint16_t>(total_samples * sizeof(int16_t));

            std::vector<uint8_t> packet(sizeof(AudioPacketHeader) + audio_header.payload_bytes);
            std::memcpy(packet.data(), &audio_header, sizeof(AudioPacketHeader));
            std::memcpy(packet.data() + sizeof(AudioPacketHeader), silence_pcm.data(), audio_header.payload_bytes);

            std::vector<sockaddr_in> target_addrs;
            {
                std::lock_guard<std::mutex> lock(g_peers_mutex);
                for (const auto& kv : g_peers) {
                    target_addrs.push_back(kv.second->addr);
                }
            }

            if (!target_addrs.empty()) {
                std::lock_guard<std::mutex> sock_lock(g_socket_send_mutex);
                for (const auto& addr : target_addrs) {
                    sendto(g_sockfd, (const char*)packet.data(), static_cast<int>(packet.size()), 0,
                           (struct sockaddr*)&addr, sizeof(addr));
                }
                g_tx_packets += static_cast<uint32_t>(target_addrs.size());
            }
        }
        int sleep_ms = (g_buffer_size * 1000) / (g_sample_rate > 0 ? g_sample_rate : 48000);
        if (sleep_ms < 5) sleep_ms = 5;
        std::this_thread::sleep_for(std::chrono::milliseconds(sleep_ms));
    }
}

// 주기적 P2P 핑 및 NAT 홀펀칭 유지 루프 (1000ms 주기: RTT 측정 및 NAT 포트 킵얼라이브)
void p2p_ping_loop() {
    while (g_running.load()) {
        if (g_sockfd != INVALID_SOCKET) {
            AudioPacketHeader ping_header{};
            ping_header.magic = SYNC_MAGIC;
            ping_header.packet_type = PACKET_TYPE_PING;
            ping_header.room_id = g_room_id;
            ping_header.user_id = g_user_id;
            ping_header.timestamp_us = get_time_us();

            std::vector<sockaddr_in> target_addrs;
            {
                std::lock_guard<std::mutex> lock(g_peers_mutex);
                for (const auto& kv : g_peers) {
                    target_addrs.push_back(kv.second->addr);
                }
            }

            if (!target_addrs.empty()) {
                std::lock_guard<std::mutex> sock_lock(g_socket_send_mutex);
                for (const auto& addr : target_addrs) {
                    sendto(g_sockfd, (const char*)&ping_header, sizeof(ping_header), 0,
                           (struct sockaddr*)&addr, sizeof(addr));
                }
                g_tx_packets += static_cast<uint32_t>(target_addrs.size());
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1000));
    }
}

extern "C" {
    EXPORT int init_audio_engine(int sample_rate, int buffer_size) {
        std::cout << "[AudioCore P2P] Initializing Audio Engine. SampleRate: " 
                  << sample_rate << ", BufferSize: " << buffer_size << " samples" << std::endl;
        
        bool params_changed = (g_sample_rate != sample_rate || g_buffer_size != buffer_size);
        g_sample_rate = sample_rate;
        g_buffer_size = buffer_size;
        g_initialized = true;

#ifdef _WIN32
        WSADATA wsaData;
        WSAStartup(MAKEWORD(2, 2), &wsaData);
#endif

        // 오디오 디바이스 파라미터 변경 시 재초기화
        if (g_ma_device_initialized.load() && params_changed) {
            ma_device_uninit(&g_ma_device);
            g_ma_device_initialized.store(false);
        }

        // miniaudio 듀플렉스 디바이스 설정 (더블 버퍼링: periods = 2)
        if (!g_ma_device_initialized.load()) {
            ma_device_config config = ma_device_config_init(ma_device_type_duplex);
            config.capture.format = ma_format_s16;
            config.capture.channels = 2;
            config.playback.format = ma_format_s16;
            config.playback.channels = 2;
            config.sampleRate = g_sample_rate;
            config.periodSizeInFrames = g_buffer_size;
            config.periods = 2;
            config.dataCallback = audio_data_callback;
            config.pUserData = nullptr;
            config.performanceProfile = ma_performance_profile_low_latency;
#ifdef _WIN32
            config.wasapi.usage = ma_wasapi_usage_pro_audio;
            config.wasapi.noAutoConvertSRC = MA_TRUE;
            config.wasapi.noDefaultQualitySRC = MA_TRUE;
            config.wasapi.noHardwareOffloading = MA_TRUE;

            ma_result init_res = MA_ERROR;
            // 1단계: WASAPI Exclusive 시도
            config.playback.shareMode = ma_share_mode_exclusive;
            config.capture.shareMode = ma_share_mode_exclusive;
            init_res = ma_device_init(nullptr, &config, &g_ma_device);

            if (init_res != MA_SUCCESS) {
                // 2단계: 출력 Exclusive + 입력 Shared 시도
                config.playback.shareMode = ma_share_mode_exclusive;
                config.capture.shareMode = ma_share_mode_shared;
                init_res = ma_device_init(nullptr, &config, &g_ma_device);
            }
            if (init_res != MA_SUCCESS) {
                // 3단계: Low-Latency Shared 모드
                config.playback.shareMode = ma_share_mode_shared;
                config.capture.shareMode = ma_share_mode_shared;
                init_res = ma_device_init(nullptr, &config, &g_ma_device);
            }
#else
            ma_result init_res = ma_device_init(nullptr, &config, &g_ma_device);
#endif

            if (init_res == MA_SUCCESS) {
                g_ma_device_initialized.store(true);
                if (g_running.load()) {
                    ma_device_start(&g_ma_device);
                }
                std::cout << "[AudioCore P2P] Audio duplex device successfully started." << std::endl;
            } else {
                // 폴백: 재생 전용 디바이스 시도
                config.deviceType = ma_device_type_playback;
                config.playback.shareMode = ma_share_mode_shared;
                if (ma_device_init(nullptr, &config, &g_ma_device) == MA_SUCCESS) {
                    g_ma_device_initialized.store(true);
                    if (g_running.load()) {
                        ma_device_start(&g_ma_device);
                    }
                    std::cout << "[AudioCore P2P] Fallback: Playback-only device initialized." << std::endl;
                } else {
                    std::cerr << "[AudioCore P2P Warning] Failed to initialize audio device." << std::endl;
                }
            }
        }

        return 0;
    }

    EXPORT void set_local_port(int port) {
        g_local_port = port;
        std::cout << "[AudioCore P2P] Local bind UDP port set to " << g_local_port << std::endl;
    }

    EXPORT void set_my_identity(int room_id, int user_id) {
        g_room_id = static_cast<uint16_t>(room_id);
        g_user_id = static_cast<uint16_t>(user_id);
        std::cout << "[AudioCore P2P] My identity updated: Room " << g_room_id 
                  << ", User " << g_user_id << std::endl;
    }

    // P2P 피어 등록 및 즉시 홀펀칭 패킷 전송
    EXPORT void add_p2p_peer(int user_id, const char* ip, int port) {
        if (!ip || std::strlen(ip) == 0 || port <= 0) return;
        uint16_t uid = static_cast<uint16_t>(user_id);
        if (uid == g_user_id) return; // 나 자신은 제외

        sockaddr_in target_addr{};
        target_addr.sin_family = AF_INET;
        target_addr.sin_port = htons(port);
        if (inet_pton(AF_INET, ip, &target_addr.sin_addr) <= 0) {
            std::cerr << "[AudioCore P2P Error] Invalid IP: " << ip << std::endl;
            return;
        }

        std::shared_ptr<PeerEndpoint> peer;
        {
            std::lock_guard<std::mutex> lock(g_peers_mutex);
            auto it = g_peers.find(uid);
            if (it != g_peers.end()) {
                peer = it->second;
                peer->ip = ip;
                peer->port = port;
                peer->addr = target_addr;
            } else {
                peer = std::make_shared<PeerEndpoint>();
                peer->user_id = uid;
                peer->ip = ip;
                peer->port = port;
                peer->addr = target_addr;
                peer->last_seen_us.store(get_time_us());
                g_peers[uid] = peer;
            }
        }

        std::cout << "[AudioCore P2P] Peer registered/updated: User " << uid 
                  << " (" << ip << ":" << port << ")" << std::endl;

        // 즉시 홀펀칭(Hole-punching) 패킷 3회 연타 전송하여 공유기 방화벽 세션 개방
        if (g_sockfd != INVALID_SOCKET) {
            AudioPacketHeader punch_header{};
            punch_header.magic = SYNC_MAGIC;
            punch_header.packet_type = PACKET_TYPE_HEARTBEAT;
            punch_header.room_id = g_room_id;
            punch_header.user_id = g_user_id;
            punch_header.timestamp_us = get_time_us();

            std::lock_guard<std::mutex> sock_lock(g_socket_send_mutex);
            for (int i = 0; i < 3; ++i) {
                sendto(g_sockfd, (const char*)&punch_header, sizeof(punch_header), 0,
                       (struct sockaddr*)&target_addr, sizeof(target_addr));
            }
            g_tx_packets += 3;
        }
    }

    EXPORT void remove_p2p_peer(int user_id) {
        uint16_t uid = static_cast<uint16_t>(user_id);
        std::lock_guard<std::mutex> lock(g_peers_mutex);
        g_peers.erase(uid);
        std::cout << "[AudioCore P2P] Peer removed: User " << uid << std::endl;
    }

    EXPORT void clear_p2p_peers() {
        std::lock_guard<std::mutex> lock(g_peers_mutex);
        g_peers.clear();
        std::cout << "[AudioCore P2P] All peers cleared." << std::endl;
    }

    EXPORT int get_p2p_peer_count() {
        std::lock_guard<std::mutex> lock(g_peers_mutex);
        return static_cast<int>(g_peers.size());
    }

    EXPORT float get_p2p_peer_rtt(int user_id) {
        uint16_t uid = static_cast<uint16_t>(user_id);
        std::lock_guard<std::mutex> lock(g_peers_mutex);
        auto it = g_peers.find(uid);
        if (it != g_peers.end()) {
            return it->second->rtt_ms.load();
        }
        return 0.0f;
    }

    // [하위 호환성 유지] set_sfu_endpoint 호출 시 P2P 피어로 자동 등록
    EXPORT void set_sfu_endpoint(const char* ip, int port, int room_id, int user_id) {
        set_my_identity(room_id, user_id);
        if (ip && std::strlen(ip) > 0 && port > 0) {
            // 호스트 또는 SFU 서버를 피어로 등록 (ID: 9999 등)
            add_p2p_peer(9999, ip, port);
        }
    }

    EXPORT void start_audio_stream() {
        if (g_running.load()) return;

        // UDP 소켓 개설
        g_sockfd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (g_sockfd == INVALID_SOCKET) {
            std::cerr << "[AudioCore Error] Failed to create UDP socket" << std::endl;
            return;
        }

        // SO_REUSEADDR 설정
        int reuse = 1;
        setsockopt(g_sockfd, SOL_SOCKET, SO_REUSEADDR, (const char*)&reuse, sizeof(reuse));

        // 저지연 소켓 버퍼 크기 설정 (128KB)
        int buf_size = 131072;
        setsockopt(g_sockfd, SOL_SOCKET, SO_RCVBUF, (const char*)&buf_size, sizeof(buf_size));
        setsockopt(g_sockfd, SOL_SOCKET, SO_SNDBUF, (const char*)&buf_size, sizeof(buf_size));

#if defined(IP_TOS)
        int tos = 0x10; // IPTOS_LOWDELAY
        setsockopt(g_sockfd, IPPROTO_IP, IP_TOS, (const char*)&tos, sizeof(tos));
#endif

        // 빠른 타임아웃
#ifdef _WIN32
        DWORD timeout_ms = 40;
        setsockopt(g_sockfd, SOL_SOCKET, SO_RCVTIMEO, (const char*)&timeout_ms, sizeof(timeout_ms));
#else
        struct timeval tv;
        tv.tv_sec = 0;
        tv.tv_usec = 40000;
        setsockopt(g_sockfd, SOL_SOCKET, SO_RCVTIMEO, (const char*)&tv, sizeof(tv));
#endif

        // P2P 수신을 위한 로컬 포트 바인딩
        sockaddr_in bind_addr{};
        bind_addr.sin_family = AF_INET;
        bind_addr.sin_addr.s_addr = INADDR_ANY;
        bind_addr.sin_port = htons(g_local_port);

        if (bind(g_sockfd, (struct sockaddr*)&bind_addr, sizeof(bind_addr)) == SOCKET_ERROR) {
            std::cout << "[AudioCore P2P] Port " << g_local_port 
                      << " busy, binding to any available ephemeral port..." << std::endl;
            bind_addr.sin_port = 0;
            bind(g_sockfd, (struct sockaddr*)&bind_addr, sizeof(bind_addr));
        }

        // 실제 바인드된 로컬 포트 확인
        socklen_t addr_len = sizeof(bind_addr);
        if (getsockname(g_sockfd, (struct sockaddr*)&bind_addr, &addr_len) == 0) {
            g_local_port = ntohs(bind_addr.sin_port);
            std::cout << "[AudioCore P2P] UDP Socket bound successfully on port " << g_local_port << std::endl;
        }

        g_running.store(true);
        g_tx_packets.store(0);
        g_rx_packets.store(0);

        // 등록된 피어들에게 방 참가(JOIN) 패킷 멀티 송신
        {
            AudioPacketHeader join_header{};
            join_header.magic = SYNC_MAGIC;
            join_header.packet_type = PACKET_TYPE_JOIN;
            join_header.room_id = g_room_id;
            join_header.user_id = g_user_id;
            join_header.timestamp_us = get_time_us();

            std::vector<sockaddr_in> target_addrs;
            {
                std::lock_guard<std::mutex> lock(g_peers_mutex);
                for (const auto& kv : g_peers) {
                    target_addrs.push_back(kv.second->addr);
                }
            }

            if (!target_addrs.empty()) {
                std::lock_guard<std::mutex> sock_lock(g_socket_send_mutex);
                for (const auto& addr : target_addrs) {
                    sendto(g_sockfd, (const char*)&join_header, sizeof(join_header), 0,
                           (struct sockaddr*)&addr, sizeof(addr));
                }
                g_tx_packets += static_cast<uint32_t>(target_addrs.size());
            }
        }

        // 백그라운드 수신, 핑, 백업 무음 송신 스레드 시작
        g_network_thread = std::thread(network_receive_loop);
        g_ping_thread = std::thread(p2p_ping_loop);

        g_hardware_callback_active.store(false);
        g_fallback_tx_running.store(true);
        g_fallback_tx_thread = std::thread(fallback_silence_tx_loop);

        // 하드웨어 오디오 스트리밍 시작
        if (!g_ma_device_initialized.load()) {
            init_audio_engine(g_sample_rate, g_buffer_size);
        }
        if (g_ma_device_initialized.load()) {
            ma_device_start(&g_ma_device);
        }

        std::cout << "[AudioCore P2P] Live P2P audio streaming started! (User ID: " 
                  << g_user_id << ", Local Port: " << g_local_port << ")" << std::endl;
    }

    EXPORT void stop_audio_stream() {
        if (!g_running.load()) return;

        g_running.store(false);
        g_fallback_tx_running.store(false);

        // 하드웨어 오디오 스트리밍 중지
        if (g_ma_device_initialized.load()) {
            ma_device_stop(&g_ma_device);
        }

        // 피어들에게 퇴장(LEAVE) 패킷 송신
        if (g_sockfd != INVALID_SOCKET) {
            AudioPacketHeader leave_header{};
            leave_header.magic = SYNC_MAGIC;
            leave_header.packet_type = PACKET_TYPE_LEAVE;
            leave_header.room_id = g_room_id;
            leave_header.user_id = g_user_id;
            leave_header.timestamp_us = get_time_us();

            std::vector<sockaddr_in> target_addrs;
            {
                std::lock_guard<std::mutex> lock(g_peers_mutex);
                for (const auto& kv : g_peers) {
                    target_addrs.push_back(kv.second->addr);
                }
            }

            if (!target_addrs.empty()) {
                std::lock_guard<std::mutex> sock_lock(g_socket_send_mutex);
                for (const auto& addr : target_addrs) {
                    sendto(g_sockfd, (const char*)&leave_header, sizeof(leave_header), 0,
                           (struct sockaddr*)&addr, sizeof(addr));
                }
            }

            closesocket(g_sockfd);
            g_sockfd = INVALID_SOCKET;
        }

        if (g_fallback_tx_thread.joinable()) g_fallback_tx_thread.join();
        if (g_network_thread.joinable()) g_network_thread.join();
        if (g_ping_thread.joinable()) g_ping_thread.join();

        // 모든 피어의 수신 큐 초기화
        {
            std::lock_guard<std::mutex> lock(g_peers_mutex);
            for (auto& kv : g_peers) {
                std::lock_guard<std::mutex> q_lock(kv.second->queue_mutex);
                kv.second->audio_queue.clear();
                kv.second->last_sample_L = 0;
                kv.second->last_sample_R = 0;
                kv.second->was_starving = false;
            }
        }

        g_in_level.store(0.0f);
        g_out_level.store(0.0f);
        std::cout << "[AudioCore P2P] Audio streaming stopped." << std::endl;
    }

    EXPORT void set_channel_volume(int user_id, float volume) {
        uint16_t uid = static_cast<uint16_t>(user_id);
        std::lock_guard<std::mutex> lock(g_peers_mutex);
        auto it = g_peers.find(uid);
        if (it != g_peers.end()) {
            it->second->volume.store(std::clamp(volume, 0.0f, 2.0f));
        }
    }

    EXPORT void set_input_gain(float gain) {
        g_input_gain.store(std::clamp(gain, 0.0f, 2.0f));
    }

    EXPORT void get_audio_stats(float* out_rtt_ms, float* out_in_level, float* out_out_level) {
        if (out_rtt_ms) *out_rtt_ms = g_current_rtt_ms.load();
        if (out_in_level) *out_in_level = g_in_level.load();
        if (out_out_level) *out_out_level = g_out_level.load();
    }

    EXPORT void get_network_stats(uint32_t* out_tx_packets, uint32_t* out_rx_packets, int* out_active_remote_peers) {
        if (out_tx_packets) *out_tx_packets = g_tx_packets.load();
        if (out_rx_packets) *out_rx_packets = g_rx_packets.load();
        if (out_active_remote_peers) {
            auto now = std::chrono::steady_clock::now();
            uint64_t now_us = get_time_us();
            std::lock_guard<std::mutex> lock(g_peers_mutex);
            int count = 0;
            for (const auto& kv : g_peers) {
                // 최근 3초 이내에 패킷이 오고 간 피어를 활성 피어로 카운트
                if (now_us - kv.second->last_seen_us.load() <= 3000000) {
                    count++;
                }
            }
            *out_active_remote_peers = count;
        }
    }

    EXPORT int is_audio_running() {
        return g_running.load() ? 1 : 0;
    }

    // 내장 SFU 릴레이 서버 (하위 호환 및 보조 중계 지원)
    namespace {
        std::atomic<bool> g_sfu_server_running{false};
        SOCKET g_sfu_server_sockfd = INVALID_SOCKET;
        std::thread g_sfu_server_thread;
        std::atomic<int> g_sfu_active_peers{0};

        struct EmbeddedPeerInfo {
            uint16_t user_id;
            sockaddr_in address;
            std::chrono::steady_clock::time_point last_seen;
        };

        void embedded_sfu_loop(int port) {
            std::cout << "[Embedded SFU] Relay server listening on UDP port " << port << std::endl;
            std::unordered_map<uint16_t, std::vector<EmbeddedPeerInfo>> rooms;
            uint8_t recv_buffer[8192];
            auto last_stats_time = std::chrono::steady_clock::now();

            while (g_sfu_server_running.load()) {
                sockaddr_in client_addr{};
                socklen_t addr_len = sizeof(client_addr);

                int bytes_received = recvfrom(
                    g_sfu_server_sockfd,
                    (char*)recv_buffer,
                    sizeof(recv_buffer),
                    0,
                    (struct sockaddr*)&client_addr,
                    &addr_len
                );

                auto now = std::chrono::steady_clock::now();

                if (bytes_received >= (int)sizeof(AudioPacketHeader)) {
                    auto* header = reinterpret_cast<AudioPacketHeader*>(recv_buffer);
                    if (header->magic == SYNC_MAGIC) {
                        uint16_t room_id = header->room_id;
                        uint16_t user_id = header->user_id;
                        auto& peer_list = rooms[room_id];

                        bool found = false;
                        for (auto& peer : peer_list) {
                            if (peer.user_id == user_id) {
                                peer.address = client_addr;
                                peer.last_seen = now;
                                found = true;
                                break;
                            }
                        }
                        if (!found && header->packet_type != PACKET_TYPE_LEAVE) {
                            peer_list.push_back({user_id, client_addr, now});
                            char ip_str[INET_ADDRSTRLEN];
                            inet_ntop(AF_INET, &(client_addr.sin_addr), ip_str, INET_ADDRSTRLEN);
                            std::cout << "[Embedded SFU Room " << room_id << "] New peer registered: User " << user_id 
                                      << " (" << ip_str << ":" << ntohs(client_addr.sin_port) << ")" << std::endl;
                        }

                        if (header->packet_type == PACKET_TYPE_AUDIO) {
                            for (const auto& peer : peer_list) {
                                if (peer.user_id != user_id) {
                                    sendto(
                                        g_sfu_server_sockfd,
                                        (const char*)recv_buffer,
                                        bytes_received,
                                        0,
                                        (struct sockaddr*)&peer.address,
                                        sizeof(peer.address)
                                    );
                                }
                            }
                        } else if (header->packet_type == PACKET_TYPE_PING) {
                            header->packet_type = PACKET_TYPE_PONG;
                            sendto(
                                g_sfu_server_sockfd,
                                (const char*)recv_buffer,
                                sizeof(AudioPacketHeader),
                                0,
                                (struct sockaddr*)&client_addr,
                                sizeof(client_addr)
                            );
                        } else if (header->packet_type == PACKET_TYPE_LEAVE) {
                            for (auto it = peer_list.begin(); it != peer_list.end(); ) {
                                if (it->user_id == user_id) {
                                    it = peer_list.erase(it);
                                } else {
                                    ++it;
                                }
                            }
                        }
                    }
                }

                if (std::chrono::duration_cast<std::chrono::seconds>(now - last_stats_time).count() >= 3) {
                    last_stats_time = now;
                    int total_active_peers = 0;

                    for (auto& pair : rooms) {
                        auto& list = pair.second;
                        for (auto it = list.begin(); it != list.end(); ) {
                            if (std::chrono::duration_cast<std::chrono::seconds>(now - it->last_seen).count() > 5) {
                                std::cout << "[Embedded SFU Room " << pair.first << "] Peer timeout: User " << it->user_id << std::endl;
                                it = list.erase(it);
                            } else {
                                ++total_active_peers;
                                ++it;
                            }
                        }
                    }
                    g_sfu_active_peers.store(total_active_peers);
                }
            }
        }
    }

    EXPORT int start_embedded_sfu(int port) {
        if (g_sfu_server_running.load()) return 0;

        g_sfu_server_sockfd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (g_sfu_server_sockfd == INVALID_SOCKET) {
            std::cerr << "[Embedded SFU Error] Failed to create UDP socket" << std::endl;
            return -1;
        }

        int reuse = 1;
        setsockopt(g_sfu_server_sockfd, SOL_SOCKET, SO_REUSEADDR, (const char*)&reuse, sizeof(reuse));

        sockaddr_in bind_addr{};
        bind_addr.sin_family = AF_INET;
        bind_addr.sin_addr.s_addr = INADDR_ANY;
        bind_addr.sin_port = htons(port);

        if (bind(g_sfu_server_sockfd, (struct sockaddr*)&bind_addr, sizeof(bind_addr)) == SOCKET_ERROR) {
            std::cerr << "[Embedded SFU Error] Failed to bind port " << port << std::endl;
            closesocket(g_sfu_server_sockfd);
            g_sfu_server_sockfd = INVALID_SOCKET;
            return -1;
        }

#ifdef _WIN32
        DWORD timeout_ms = 100;
        setsockopt(g_sfu_server_sockfd, SOL_SOCKET, SO_RCVTIMEO, (const char*)&timeout_ms, sizeof(timeout_ms));
#else
        struct timeval tv;
        tv.tv_sec = 0;
        tv.tv_usec = 100000;
        setsockopt(g_sfu_server_sockfd, SOL_SOCKET, SO_RCVTIMEO, (const char*)&tv, sizeof(tv));
#endif

        g_sfu_server_running.store(true);
        g_sfu_server_thread = std::thread(embedded_sfu_loop, port);
        std::cout << "[Embedded SFU] Server started successfully on port " << port << std::endl;
        return 0;
    }

    EXPORT void stop_embedded_sfu() {
        if (!g_sfu_server_running.load()) return;

        std::cout << "[Embedded SFU] Stopping server..." << std::endl;
        g_sfu_server_running.store(false);

        if (g_sfu_server_sockfd != INVALID_SOCKET) {
            closesocket(g_sfu_server_sockfd);
            g_sfu_server_sockfd = INVALID_SOCKET;
        }

        if (g_sfu_server_thread.joinable()) {
            g_sfu_server_thread.join();
        }

        g_sfu_active_peers.store(0);
        std::cout << "[Embedded SFU] Server stopped." << std::endl;
    }

    EXPORT int is_sfu_running() {
        return g_sfu_server_running.load() ? 1 : 0;
    }

    EXPORT int get_sfu_peer_count() {
        return g_sfu_active_peers.load();
    }
}