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

#include "audio_core.h"
#include "protocol.h"

namespace {
    // 엔진 상태
    std::atomic<bool> g_initialized{false};
    std::atomic<bool> g_running{false};
    int g_sample_rate = 48000;
    int g_buffer_size = 128; // 프레임 단위 (128 samples = 2.67ms @ 48kHz)

    // SFU 접속 정보
    std::string g_sfu_ip = "127.0.0.1";
    int g_sfu_port = 9999;
    uint16_t g_room_id = 1;
    uint16_t g_user_id = 101;

    // 볼륨 및 레벨
    std::mutex g_volume_mutex;
    std::unordered_map<int, float> g_peer_volumes;
    std::atomic<float> g_input_gain{1.0f};
    std::atomic<float> g_in_level{0.0f};
    std::atomic<float> g_out_level{0.0f};
    std::atomic<float> g_current_rtt_ms{0.0f};

    // 네트워크 진단 지표
    std::atomic<uint32_t> g_tx_packets{0};
    std::atomic<uint32_t> g_rx_packets{0};
    std::atomic<uint32_t> g_sequence_counter{0};
    std::mutex g_remote_peers_mutex;
    std::unordered_map<uint16_t, std::chrono::steady_clock::time_point> g_remote_peers;

    // 네트워크 소켓 및 스레드
    SOCKET g_sockfd = INVALID_SOCKET;
    sockaddr_in g_sfu_addr{};
    std::thread g_network_thread;
    std::thread g_ping_thread;

    // 하드웨어 오디오 디바이스 (miniaudio)
    ma_device g_ma_device;
    std::atomic<bool> g_ma_device_initialized{false};
    std::atomic<bool> g_hardware_callback_active{false};
    std::atomic<bool> g_fallback_tx_running{false};
    std::thread g_fallback_tx_thread;

    // 수신 오디오 지터 큐 (Thread-safe)
    std::mutex g_jitter_mutex;
    std::deque<int16_t> g_playback_queue;
    std::atomic<size_t> g_incoming_packet_samples{0};
    int16_t g_last_playback_sample_L = 0;
    int16_t g_last_playback_sample_R = 0;
    bool g_playback_was_starving = false;

    // 아날로그 새츄레이션 기반 부드러운 소프트 리미터:
    // 정상 레벨(-2 dBFS 이하)에서는 100% 완전 투명(선형 유지),
    // 초과 시 tanh 기반의 부드러운 아날로그 포화 곡선으로 라운딩하여
    // 귀를 찌르는 사각파 하드 클리핑("지지직" 디지털 왜곡)을 완벽하게 제거
    inline int16_t soft_clip(float x) {
        const float threshold = 26214.0f; // -1.9 dBFS까지 100% 무손실 선형 유지
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

    // 초저지연 실시간 합주를 위한 지터 버퍼 한도 (기본 15~20ms)
    inline size_t get_target_queue_limit() {
        size_t limit = static_cast<size_t>(g_buffer_size * 2 * 6);
        if (limit < 1536) limit = 1536;
        if (limit > 8192) limit = 8192;
        return limit;
    }

    uint64_t get_time_us() {
        return std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::steady_clock::now().time_since_epoch()
        ).count();
    }

    // miniaudio Duplex 콜백 (마이크 입력 + 스피커 출력 동시 처리)
    void audio_data_callback(ma_device* pDevice, void* pOutput, const void* pInput, ma_uint32 frameCount) {
        g_hardware_callback_active.store(true);

        ma_uint32 cap_channels = (pDevice->capture.channels > 0) ? pDevice->capture.channels : 1;
        ma_uint32 play_channels = (pDevice->playback.channels > 0) ? pDevice->playback.channels : 2;
        ma_uint32 play_samples = frameCount * play_channels;

        // 1. 마이크 입력 처리 (Capture)
        if (g_running.load()) {
            ma_uint32 net_channels = 2; // 패킷은 항상 2채널 스테레오로 통일하여 전송
            ma_uint32 net_samples = frameCount * net_channels;
            std::vector<int16_t> processed_pcm(net_samples, 0);

            if (pInput != nullptr) {
                const int16_t* in_pcm = reinterpret_cast<const int16_t*>(pInput);
                float gain = g_input_gain.load();
                double sum_sq = 0.0;

                for (ma_uint32 f = 0; f < frameCount; ++f) {
                    if (cap_channels == 1) {
                        // 모노 마이크(맥북 내장 마이크 등) 입력을 좌/우 채널로 복제하여
                        // 2배속 칩멍크 왜곡 및 위상 반전 노이즈를 완벽 해결
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

                // 실제 RMS 입력 게인 레벨 계산
                float rms = std::sqrt(sum_sq / (frameCount > 0 ? frameCount : 1));
                float target_level = std::clamp(rms * 4.5f, 0.0f, 1.0f);
                float current = g_in_level.load();
                if (target_level > current) {
                    g_in_level.store(target_level);
                } else {
                    g_in_level.store(current * 0.82f + target_level * 0.18f);
                }
            } else {
                g_in_level.store(g_in_level.load() * 0.75f);
            }

            // UDP 오디오 패킷 생성 및 SFU 전송
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

                sendto(g_sockfd, (const char*)packet.data(), static_cast<int>(packet.size()), 0,
                       (struct sockaddr*)&g_sfu_addr, sizeof(g_sfu_addr));
                g_tx_packets++;
            }
        }

        // 2. 스피커 출력 처리 (Playback)
        if (pOutput != nullptr) {
            int16_t* out_pcm = reinterpret_cast<int16_t*>(pOutput);
            std::memset(out_pcm, 0, play_samples * sizeof(int16_t));

            if (g_running.load()) {
                std::lock_guard<std::mutex> lock(g_jitter_mutex);

                // 장기 지연 누적 방지(Catch-up):
                // 정상적인 패킷 뭉침(마이크로 버스트 15~20ms)은 버리지 않고 그대로 유지하며,
                // 심각한 네트워크 정체(약 50ms 이상 적체) 발생 시에만 좌/우 프레임 페어(2개 샘플) 단위로 안전 정리
                constexpr size_t MAX_ACCEPTABLE_QUEUE = 4800; // ~50ms @ 48kHz stereo
                while (g_playback_queue.size() > MAX_ACCEPTABLE_QUEUE && g_playback_queue.size() >= 2) {
                    g_playback_queue.pop_front();
                    g_playback_queue.pop_front();
                }

                size_t available = g_playback_queue.size();
                size_t to_read = std::min(static_cast<size_t>(play_samples), available);
                to_read = (to_read / 2) * 2; // 스테레오 프레임(L/R) 정렬 보장

                // 큐에서 패킷 데이터를 읽어 스피커로 전달
                for (size_t i = 0; i < to_read; ++i) {
                    out_pcm[i] = g_playback_queue.front();
                    g_playback_queue.pop_front();
                }

                // 직전 버퍼 고갈(Starvation) 이후 새로 패킷이 들어올 때 첫 4샘플 마이크로 페이드인 (팝 잡음 방지)
                if (g_playback_was_starving && to_read >= 4) {
                    out_pcm[0] = static_cast<int16_t>(out_pcm[0] * 0.25f);
                    out_pcm[1] = static_cast<int16_t>(out_pcm[1] * 0.25f);
                    out_pcm[2] = static_cast<int16_t>(out_pcm[2] * 0.60f);
                    out_pcm[3] = static_cast<int16_t>(out_pcm[3] * 0.60f);
                    g_playback_was_starving = false;
                }

                // 언더런(버퍼 고갈) 발생 시 급격한 0 드롭(디지털 스텝 임펄스 잡음) 방지:
                // 이전 마지막 샘플에서 지수 감쇄(Exponential Decay)로 부드럽게 0으로 수렴시켜
                // "지지직"거리는 디지털 클리핑 및 틱 잡음을 완벽 차단
                if (to_read < play_samples) {
                    g_playback_was_starving = true;
                    int16_t last_L = (to_read >= 2) ? out_pcm[to_read - 2] : g_last_playback_sample_L;
                    int16_t last_R = (to_read >= 1) ? out_pcm[to_read - 1] : g_last_playback_sample_R;
                    for (size_t i = to_read; i < play_samples; i += 2) {
                        last_L = static_cast<int16_t>(last_L * 0.85f);
                        last_R = static_cast<int16_t>(last_R * 0.85f);
                        out_pcm[i] = last_L;
                        if (i + 1 < play_samples) {
                            out_pcm[i + 1] = last_R;
                        }
                    }
                }

                // 마지막 샘플 상태 저장 (다음 콜백 시작 시 불연속 방지용)
                if (play_samples >= 2) {
                    g_last_playback_sample_L = out_pcm[play_samples - 2];
                    g_last_playback_sample_R = out_pcm[play_samples - 1];
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
                g_last_playback_sample_L = 0;
                g_last_playback_sample_R = 0;
                g_playback_was_starving = false;
            }
        }
    }
}

// 백그라운드 UDP 패킷 수신 및 오디오 지터 버퍼링
void network_receive_loop() {
    uint8_t buffer[8192];
    sockaddr_in from_addr{};
    socklen_t from_len = sizeof(from_addr);

    while (g_running) {
        int bytes = recvfrom(g_sockfd, (char*)buffer, sizeof(buffer), 0,
                             (struct sockaddr*)&from_addr, &from_len);

        if (bytes >= (int)sizeof(AudioPacketHeader)) {
            auto* header = reinterpret_cast<AudioPacketHeader*>(buffer);
            if (header->magic == SYNC_MAGIC) {
                if (header->packet_type == PACKET_TYPE_PONG) {
                    uint64_t now_us = get_time_us();
                    if (now_us > header->timestamp_us) {
                        float rtt = (now_us - header->timestamp_us) / 1000.0f;
                        g_current_rtt_ms.store(rtt);
                    }
                } else if (header->packet_type == PACKET_TYPE_AUDIO) {
                    // 나 자신의 패킷 에코가 아니라면 상대방 오디오 패킷 수신
                    if (header->user_id != g_user_id) {
                        g_rx_packets++;

                        // 활성 피어 갱신
                        {
                            std::lock_guard<std::mutex> p_lock(g_remote_peers_mutex);
                            g_remote_peers[header->user_id] = std::chrono::steady_clock::now();
                        }

                        int samples = header->payload_bytes / sizeof(int16_t);
                        g_incoming_packet_samples.store(static_cast<size_t>(samples));
                        const int16_t* pcm = reinterpret_cast<const int16_t*>(buffer + sizeof(AudioPacketHeader));

                        float vol = 1.0f;
                        {
                            std::lock_guard<std::mutex> v_lock(g_volume_mutex);
                            auto it = g_peer_volumes.find(header->user_id);
                            if (it != g_peer_volumes.end()) {
                                vol = it->second;
                            }
                        }

                        // 지터 큐에 추가: 패킷이 뭉쳐와도 버리지 않고 큐에 차곡차곡 보관하여
                        // 오디오 하드웨어 콜백이 스피커로 끊김 없이 자연스럽게 흘려보낼 수 있게 함
                        {
                            std::lock_guard<std::mutex> q_lock(g_jitter_mutex);
                            if (header->channels == 1) {
                                // 1채널 모노 패킷인 경우 L/R로 복제하여 2채널 큐에 추가
                                for (int i = 0; i < samples; ++i) {
                                    float val = pcm[i] * vol;
                                    int16_t s = soft_clip_s16(val);
                                    g_playback_queue.push_back(s);
                                    g_playback_queue.push_back(s);
                                }
                            } else {
                                // 2채널 스테레오 패킷
                                for (int i = 0; i < samples; ++i) {
                                    float val = pcm[i] * vol;
                                    int16_t s = soft_clip_s16(val);
                                    g_playback_queue.push_back(s);
                                }
                            }

                            // 극단적인 비정상 네트워크 정체(100ms 이상 통신 일시 중단 후 수십 개 패킷 동시 도달) 시에만
                            // 안전 상한선(약 100ms)을 초과하는 오래된 데이터만 페어(L/R) 단위로 정리
                            // 일상적인 패킷 뭉침(마이크로 버스트 10~25ms)은 절대로 버리지 않음!
                            constexpr size_t EMERGENCY_MAX_QUEUE = 9600; // ~100ms @ 48kHz stereo
                            while (g_playback_queue.size() > EMERGENCY_MAX_QUEUE) {
                                g_playback_queue.pop_front();
                                if (!g_playback_queue.empty()) g_playback_queue.pop_front();
                            }
                        }
                    }
                }
            }
        }
    }
}

// 하드웨어 오디오 콜백이 동작하지 않거나 대기 중일 때 동작하는 백업 무음 패킷 송신 루프
void fallback_silence_tx_loop() {
    // 하드웨어 콜백이 300ms 내에 동작하지 않을 경우 무음 오디오 패킷 송출로 세션 유지 및 홀펀칭
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

            sendto(g_sockfd, (const char*)packet.data(), static_cast<int>(packet.size()), 0,
                   (struct sockaddr*)&g_sfu_addr, sizeof(g_sfu_addr));
            g_tx_packets++;
        }
        int sleep_ms = (g_buffer_size * 1000) / (g_sample_rate > 0 ? g_sample_rate : 48000);
        if (sleep_ms < 5) sleep_ms = 5;
        std::this_thread::sleep_for(std::chrono::milliseconds(sleep_ms));
    }
}

// 500ms 주기 핑 전송 루프 (RTT 측정용 및 Keep-Alive)
void ping_loop() {
    while (g_running) {
        if (g_sockfd != INVALID_SOCKET) {
            AudioPacketHeader ping_header{};
            ping_header.magic = SYNC_MAGIC;
            ping_header.packet_type = PACKET_TYPE_PING;
            ping_header.room_id = g_room_id;
            ping_header.user_id = g_user_id;
            ping_header.timestamp_us = get_time_us();
            sendto(g_sockfd, (const char*)&ping_header, sizeof(ping_header), 0,
                   (struct sockaddr*)&g_sfu_addr, sizeof(g_sfu_addr));
            g_tx_packets++;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(500));
    }
}

extern "C" {
    EXPORT int init_audio_engine(int sample_rate, int buffer_size) {
        std::cout << "[AudioCore] Initializing Audio Engine. SampleRate: " 
                  << sample_rate << ", BufferSize: " << buffer_size << " samples" << std::endl;
        
        bool params_changed = (g_sample_rate != sample_rate || g_buffer_size != buffer_size);
        g_sample_rate = sample_rate;
        g_buffer_size = buffer_size;
        g_initialized = true;

#ifdef _WIN32
        WSADATA wsaData;
        WSAStartup(MAKEWORD(2, 2), &wsaData);
#endif

        // 만약 이미 디바이스가 초기화되었고 버퍼 크기 등이 바뀌었다면 재초기화
        if (g_ma_device_initialized.load() && params_changed) {
            ma_device_uninit(&g_ma_device);
            g_ma_device_initialized.store(false);
        }

        // miniaudio 듀플렉스 디바이스 설정 (최소 더블 버퍼링: periods = 2)
        if (!g_ma_device_initialized.load()) {
            ma_device_config config = ma_device_config_init(ma_device_type_duplex);
            config.capture.format = ma_format_s16;
            config.capture.channels = 2;
            config.playback.format = ma_format_s16;
            config.playback.channels = 2;
            config.sampleRate = g_sample_rate;
            config.periodSizeInFrames = g_buffer_size;
            config.periods = 2; // 최소 더블 버퍼링으로 하드웨어 대기 지연 원천 차단
            config.dataCallback = audio_data_callback;
            config.pUserData = nullptr;
            config.performanceProfile = ma_performance_profile_low_latency;
#ifdef _WIN32
            // Windows 멀티미디어 실시간 스케줄러(MMCSS) "Pro Audio" 우선순위 등록 및 믹서 우회 플래그
            config.wasapi.usage = ma_wasapi_usage_pro_audio;
            config.wasapi.noAutoConvertSRC = MA_TRUE;
            config.wasapi.noDefaultQualitySRC = MA_TRUE;
            config.wasapi.noHardwareOffloading = MA_TRUE;

            ma_result init_res = MA_ERROR;

            // 1단계: Windows OS 사운드 믹서(audiodg.exe 20ms 지연)를 원천 우회하는 WASAPI Exclusive(단독) 모드 시도
            config.playback.shareMode = ma_share_mode_exclusive;
            config.capture.shareMode = ma_share_mode_exclusive;
            init_res = ma_device_init(nullptr, &config, &g_ma_device);

            if (init_res == MA_SUCCESS) {
                std::cout << "[AudioCore] Hardware audio duplex initialized in WASAPI Exclusive Mode (Zero OS Mixer Latency)." << std::endl;
            } else {
                // 2단계: 양방향 Exclusive가 불가할 경우 출력 Exclusive + 입력 Shared 시도
                config.playback.shareMode = ma_share_mode_exclusive;
                config.capture.shareMode = ma_share_mode_shared;
                init_res = ma_device_init(nullptr, &config, &g_ma_device);

                if (init_res == MA_SUCCESS) {
                    std::cout << "[AudioCore] Hardware audio duplex initialized with Playback Exclusive Mode." << std::endl;
                } else {
                    // 3단계: Exclusive가 불가능한 경우 (타 앱 점유 등) IAudioClient3 초저지연 Shared + Pro Audio MMCSS 모드로 안전 폴백
                    config.playback.shareMode = ma_share_mode_shared;
                    config.capture.shareMode = ma_share_mode_shared;
                    init_res = ma_device_init(nullptr, &config, &g_ma_device);

                    if (init_res == MA_SUCCESS) {
                        std::cout << "[AudioCore] Hardware audio duplex initialized in WASAPI Low-Latency Shared Mode (Pro Audio MMCSS)." << std::endl;
                    }
                }
            }
#else
            ma_result init_res = ma_device_init(nullptr, &config, &g_ma_device);
#endif

            if (init_res == MA_SUCCESS) {
                g_ma_device_initialized.store(true);
                if (g_running.load()) {
                    ma_device_start(&g_ma_device);
                }
                std::cout << "[AudioCore] Hardware audio duplex device successfully started (Buffer: " 
                          << g_buffer_size << ", Periods: 2)." << std::endl;
            } else {
                std::cerr << "[AudioCore Warning] Failed to initialize duplex audio device. Trying playback-only fallback..." << std::endl;
                config.deviceType = ma_device_type_playback;
                config.playback.shareMode = ma_share_mode_shared;
                if (ma_device_init(nullptr, &config, &g_ma_device) == MA_SUCCESS) {
                    g_ma_device_initialized.store(true);
                    if (g_running.load()) {
                        ma_device_start(&g_ma_device);
                    }
                    std::cout << "[AudioCore] Fallback: Playback-only audio device initialized." << std::endl;
                } else {
                    std::cerr << "[AudioCore Warning] Failed to initialize playback audio device. Result: " << init_res << std::endl;
                }
            }
        }

        return 0; // Success
    }

    EXPORT void set_sfu_endpoint(const char* ip, int port, int room_id, int user_id) {
        if (ip != nullptr && std::strlen(ip) > 0) {
            g_sfu_ip = ip;
        }
        g_sfu_port = port;
        g_room_id = static_cast<uint16_t>(room_id);
        g_user_id = static_cast<uint16_t>(user_id);

        std::memset(&g_sfu_addr, 0, sizeof(g_sfu_addr));
        g_sfu_addr.sin_family = AF_INET;
        g_sfu_addr.sin_port = htons(g_sfu_port);
        inet_pton(AF_INET, g_sfu_ip.c_str(), &g_sfu_addr.sin_addr);

        std::cout << "[AudioCore] SFU Target configured: " << g_sfu_ip << ":" << g_sfu_port 
                  << " (Room: " << g_room_id << ", User: " << g_user_id << ")" << std::endl;
    }

    EXPORT void start_audio_stream() {
        if (g_running.load()) return;

        // 큐 초기화 (이전 세션 잔여 데이터 제거)
        {
            std::lock_guard<std::mutex> lock(g_jitter_mutex);
            g_playback_queue.clear();
            g_last_playback_sample_L = 0;
            g_last_playback_sample_R = 0;
            g_playback_was_starving = false;
        }

        // UDP 소켓 개설
        g_sockfd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (g_sockfd == INVALID_SOCKET) {
            std::cerr << "[AudioCore Error] Failed to create UDP socket" << std::endl;
            return;
        }

        // 저지연 소켓 버퍼 크기 설정 (64KB - 과도한 OS 버퍼링 방지)
        int buf_size = 65536;
        setsockopt(g_sockfd, SOL_SOCKET, SO_RCVBUF, (const char*)&buf_size, sizeof(buf_size));
        setsockopt(g_sockfd, SOL_SOCKET, SO_SNDBUF, (const char*)&buf_size, sizeof(buf_size));

#if defined(IP_TOS)
        int tos = 0x10; // IPTOS_LOWDELAY
        setsockopt(g_sockfd, IPPROTO_IP, IP_TOS, (const char*)&tos, sizeof(tos));
#endif

        // 빠른 타임아웃
#ifdef _WIN32
        DWORD timeout_ms = 50;
        setsockopt(g_sockfd, SOL_SOCKET, SO_RCVTIMEO, (const char*)&timeout_ms, sizeof(timeout_ms));
#else
        struct timeval tv;
        tv.tv_sec = 0;
        tv.tv_usec = 50000;
        setsockopt(g_sockfd, SOL_SOCKET, SO_RCVTIMEO, (const char*)&tv, sizeof(tv));
#endif

        g_running.store(true);
        g_tx_packets.store(0);
        g_rx_packets.store(0);

        // SFU 방 참여 패킷 전송
        AudioPacketHeader join_header{};
        join_header.magic = SYNC_MAGIC;
        join_header.packet_type = PACKET_TYPE_JOIN;
        join_header.room_id = g_room_id;
        join_header.user_id = g_user_id;
        join_header.timestamp_us = get_time_us();
        sendto(g_sockfd, (const char*)&join_header, sizeof(join_header), 0,
               (struct sockaddr*)&g_sfu_addr, sizeof(g_sfu_addr));
        g_tx_packets++;

        // 백그라운드 수신, 핑, 백업 무음 송신 스레드 시작
        g_network_thread = std::thread(network_receive_loop);
        g_ping_thread = std::thread(ping_loop);

        g_hardware_callback_active.store(false);
        g_fallback_tx_running.store(true);
        g_fallback_tx_thread = std::thread(fallback_silence_tx_loop);

        // 만약 하드웨어 디바이스가 초기화되지 않았다면 재시도
        if (!g_ma_device_initialized.load()) {
            init_audio_engine(g_sample_rate, g_buffer_size);
        }

        // 하드웨어 오디오 스트리밍 시작
        if (g_ma_device_initialized.load()) {
            ma_device_start(&g_ma_device);
        }

        std::cout << "[AudioCore] Live audio streaming started via UDP to " << g_sfu_ip << ":" << g_sfu_port 
                  << " (User ID: " << g_user_id << ")" << std::endl;
    }

    EXPORT void stop_audio_stream() {
        if (!g_running.load()) return;

        g_running.store(false);
        g_fallback_tx_running.store(false);

        // 하드웨어 오디오 스트리밍 중지
        if (g_ma_device_initialized.load()) {
            ma_device_stop(&g_ma_device);
        }

        // 방 퇴장 패킷 전송
        if (g_sockfd != INVALID_SOCKET) {
            AudioPacketHeader leave_header{};
            leave_header.magic = SYNC_MAGIC;
            leave_header.packet_type = PACKET_TYPE_LEAVE;
            leave_header.room_id = g_room_id;
            leave_header.user_id = g_user_id;
            leave_header.timestamp_us = get_time_us();
            sendto(g_sockfd, (const char*)&leave_header, sizeof(leave_header), 0,
                   (struct sockaddr*)&g_sfu_addr, sizeof(g_sfu_addr));

            closesocket(g_sockfd);
            g_sockfd = INVALID_SOCKET;
        }

        if (g_fallback_tx_thread.joinable()) g_fallback_tx_thread.join();
        if (g_network_thread.joinable()) g_network_thread.join();
        if (g_ping_thread.joinable()) g_ping_thread.join();

        // 큐 초기화
        {
            std::lock_guard<std::mutex> lock(g_jitter_mutex);
            g_playback_queue.clear();
            g_last_playback_sample_L = 0;
            g_last_playback_sample_R = 0;
            g_playback_was_starving = false;
        }

        g_in_level.store(0.0f);
        g_out_level.store(0.0f);
        std::cout << "[AudioCore] Audio streaming stopped." << std::endl;
    }

    EXPORT void set_channel_volume(int user_id, float volume) {
        std::lock_guard<std::mutex> lock(g_volume_mutex);
        g_peer_volumes[user_id] = std::clamp(volume, 0.0f, 2.0f);
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
            std::lock_guard<std::mutex> lock(g_remote_peers_mutex);
            int count = 0;
            for (auto it = g_remote_peers.begin(); it != g_remote_peers.end(); ) {
                if (std::chrono::duration_cast<std::chrono::seconds>(now - it->second).count() <= 3) {
                    count++;
                    ++it;
                } else {
                    it = g_remote_peers.erase(it);
                }
            }
            *out_active_remote_peers = count;
        }
    }

    EXPORT int is_audio_running() {
        return g_running.load() ? 1 : 0;
    }

    // 내장 SFU 릴레이 서버 상태 및 스레드
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

            while (g_sfu_server_running) {
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
                            // 오디오 패킷을 송신자(user_id)를 제외한 모든 방 참가자에게 포워딩
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

                // 3초마다 비활성 세션 정리 및 피어 통계 갱신
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

        // SO_REUSEADDR
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

        // 수신 타임아웃 설정
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