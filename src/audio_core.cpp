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

#ifdef _WIN32
    #ifndef NOMINMAX
        #define NOMINMAX
    #endif
    #include <winsock2.h>
    #include <ws2tcpip.h>
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

    // 네트워크
    SOCKET g_sockfd = INVALID_SOCKET;
    sockaddr_in g_sfu_addr{};
    std::thread g_network_thread;
    std::thread g_audio_io_thread;
    std::atomic<uint32_t> g_sequence_counter{0};

    uint64_t get_time_us() {
        return std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::steady_clock::now().time_since_epoch()
        ).count();
    }
}

// 백그라운드 UDP 패킷 수신 및 RTT 갱신 루프
void network_receive_loop() {
    uint8_t buffer[4096];
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
                    // 상대방 오디오 패킷 수신: 레벨 미터 계산 및 지터 버퍼 공급
                    int samples = header->payload_bytes / sizeof(int16_t);
                    const int16_t* pcm = reinterpret_cast<const int16_t*>(buffer + sizeof(AudioPacketHeader));
                    
                    float sum_sq = 0.0f;
                    for (int i = 0; i < samples; ++i) {
                        float s = pcm[i] / 32768.0f;
                        sum_sq += s * s;
                    }
                    float rms = std::sqrt(sum_sq / (samples > 0 ? samples : 1));
                    // 감쇄 적용
                    g_out_level.store((std::max)(rms * 1.5f, g_out_level.load() * 0.85f));
                }
            }
        }
    }
}

// 오디오 I/O 루프 (오인페 캡처 시뮬레이션 및 전송 + 핑)
void audio_io_loop() {
    // 128 샘플 주기: 128 / 48000 = 약 2.666 ms
    auto interval = std::chrono::microseconds(static_cast<int>(1000000.0 * g_buffer_size / g_sample_rate));
    std::vector<int16_t> pcm_buffer(g_buffer_size * 2, 0); // 스테레오

    auto last_ping = std::chrono::steady_clock::now();

    while (g_running) {
        auto frame_start = std::chrono::steady_clock::now();

        // 1초마다 핑 전송 (RTT 측정)
        auto now = std::chrono::steady_clock::now();
        if (std::chrono::duration_cast<std::chrono::milliseconds>(now - last_ping).count() >= 1000) {
            last_ping = now;
            AudioPacketHeader ping_header{};
            ping_header.magic = SYNC_MAGIC;
            ping_header.packet_type = PACKET_TYPE_PING;
            ping_header.room_id = g_room_id;
            ping_header.user_id = g_user_id;
            ping_header.timestamp_us = get_time_us();
            sendto(g_sockfd, (const char*)&ping_header, sizeof(ping_header), 0,
                   (struct sockaddr*)&g_sfu_addr, sizeof(g_sfu_addr));
        }

        // 오디오 패킷 생성 (무압축 PCM16)
        AudioPacketHeader audio_header{};
        audio_header.magic = SYNC_MAGIC;
        audio_header.packet_type = PACKET_TYPE_AUDIO;
        audio_header.room_id = g_room_id;
        audio_header.user_id = g_user_id;
        audio_header.sequence_num = ++g_sequence_counter;
        audio_header.timestamp_us = get_time_us();
        audio_header.sample_rate = static_cast<uint16_t>(g_sample_rate);
        audio_header.channels = 2;
        audio_header.bits_per_sample = 16;
        audio_header.frame_count = static_cast<uint16_t>(g_buffer_size);
        audio_header.payload_bytes = static_cast<uint16_t>(pcm_buffer.size() * sizeof(int16_t));

        // 패킷 전송용 버퍼 구성
        std::vector<uint8_t> packet(sizeof(AudioPacketHeader) + audio_header.payload_bytes);
        std::memcpy(packet.data(), &audio_header, sizeof(AudioPacketHeader));
        std::memcpy(packet.data() + sizeof(AudioPacketHeader), pcm_buffer.data(), audio_header.payload_bytes);

        sendto(g_sockfd, (const char*)packet.data(), static_cast<int>(packet.size()), 0,
               (struct sockaddr*)&g_sfu_addr, sizeof(g_sfu_addr));

        // 입력 레벨 감쇄
        g_in_level.store((std::max)(0.05f, g_in_level.load() * 0.85f));

        // 정확한 오디오 버퍼 주기 유지 (휴면)
        auto elapsed = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - frame_start);
        if (elapsed < interval) {
            std::this_thread::sleep_for(interval - elapsed);
        }
    }
}

extern "C" {
    EXPORT int init_audio_engine(int sample_rate, int buffer_size) {
        std::cout << "[AudioCore] Initializing Audio Engine. SampleRate: " 
                  << sample_rate << ", BufferSize: " << buffer_size << " samples" << std::endl;
        
        g_sample_rate = sample_rate;
        g_buffer_size = buffer_size;
        g_initialized = true;

#ifdef _WIN32
        WSADATA wsaData;
        WSAStartup(MAKEWORD(2, 2), &wsaData);
#endif
        return 0; // Success
    }

    EXPORT void set_sfu_endpoint(const char* ip, int port, int room_id, int user_id) {
        if (ip != nullptr) {
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
        if (g_running) return;

        // UDP 소켓 개설
        g_sockfd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (g_sockfd == INVALID_SOCKET) {
            std::cerr << "[AudioCore Error] Failed to create UDP socket" << std::endl;
            return;
        }

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

        g_running = true;

        // SFU 방 참여 패킷 전송
        AudioPacketHeader join_header{};
        join_header.magic = SYNC_MAGIC;
        join_header.packet_type = PACKET_TYPE_JOIN;
        join_header.room_id = g_room_id;
        join_header.user_id = g_user_id;
        join_header.timestamp_us = get_time_us();
        sendto(g_sockfd, (const char*)&join_header, sizeof(join_header), 0,
               (struct sockaddr*)&g_sfu_addr, sizeof(g_sfu_addr));

        // 백그라운드 스레드 시작
        g_network_thread = std::thread(network_receive_loop);
        g_audio_io_thread = std::thread(audio_io_loop);

        std::cout << "[AudioCore] Audio streaming started via UDP to SFU." << std::endl;
    }

    EXPORT void stop_audio_stream() {
        if (!g_running) return;

        g_running = false;

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

        if (g_network_thread.joinable()) g_network_thread.join();
        if (g_audio_io_thread.joinable()) g_audio_io_thread.join();

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

    EXPORT int is_audio_running() {
        return g_running ? 1 : 0;
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
            uint8_t recv_buffer[4096];
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

                // 3초마다 타임아웃 세션 정리
                if (std::chrono::duration_cast<std::chrono::seconds>(now - last_stats_time).count() >= 3) {
                    last_stats_time = now;
                    int total_active_peers = 0;

                    for (auto it = rooms.begin(); it != rooms.end(); ) {
                        auto& peer_list = it->second;
                        for (auto p_it = peer_list.begin(); p_it != peer_list.end(); ) {
                            auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(now - p_it->last_seen).count();
                            if (elapsed > 5) {
                                p_it = peer_list.erase(p_it);
                            } else {
                                ++p_it;
                            }
                        }
                        if (peer_list.empty()) {
                            it = rooms.erase(it);
                        } else {
                            total_active_peers += static_cast<int>(peer_list.size());
                            ++it;
                        }
                    }
                    g_sfu_active_peers.store(total_active_peers);
                }
            }
            std::cout << "[Embedded SFU] Loop exited." << std::endl;
        }
    }

    EXPORT int start_embedded_sfu(int port) {
        if (g_sfu_server_running.load()) {
            std::cout << "[Embedded SFU] Server already running on port " << port << std::endl;
            return 0;
        }

#ifdef _WIN32
        WSADATA wsaData;
        WSAStartup(MAKEWORD(2, 2), &wsaData);
#endif

        g_sfu_server_sockfd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (g_sfu_server_sockfd == INVALID_SOCKET) {
            std::cerr << "[Embedded SFU Error] Failed to create socket" << std::endl;
            return -1;
        }

        int opt = 1;
        setsockopt(g_sfu_server_sockfd, SOL_SOCKET, SO_REUSEADDR, (const char*)&opt, sizeof(opt));
#ifndef _WIN32
        setsockopt(g_sfu_server_sockfd, SOL_SOCKET, SO_REUSEPORT, (const char*)&opt, sizeof(opt));
#endif

        int buf_size = 1024 * 1024;
        setsockopt(g_sfu_server_sockfd, SOL_SOCKET, SO_RCVBUF, (const char*)&buf_size, sizeof(buf_size));
        setsockopt(g_sfu_server_sockfd, SOL_SOCKET, SO_SNDBUF, (const char*)&buf_size, sizeof(buf_size));

#ifdef _WIN32
        DWORD timeout_ms = 50;
        setsockopt(g_sfu_server_sockfd, SOL_SOCKET, SO_RCVTIMEO, (const char*)&timeout_ms, sizeof(timeout_ms));
#else
        struct timeval tv;
        tv.tv_sec = 0;
        tv.tv_usec = 50000;
        setsockopt(g_sfu_server_sockfd, SOL_SOCKET, SO_RCVTIMEO, (const char*)&tv, sizeof(tv));
#endif

        sockaddr_in server_addr{};
        server_addr.sin_family = AF_INET;
        server_addr.sin_addr.s_addr = INADDR_ANY;
        server_addr.sin_port = htons(port);

        if (bind(g_sfu_server_sockfd, (struct sockaddr*)&server_addr, sizeof(server_addr)) == SOCKET_ERROR) {
            std::cerr << "[Embedded SFU Error] Failed to bind to port " << port << std::endl;
            closesocket(g_sfu_server_sockfd);
            g_sfu_server_sockfd = INVALID_SOCKET;
            return -1;
        }

        g_sfu_server_running = true;
        g_sfu_server_thread = std::thread(embedded_sfu_loop, port);
        std::cout << "[Embedded SFU] Server started successfully on port " << port << std::endl;
        return 0;
    }

    EXPORT void stop_embedded_sfu() {
        if (!g_sfu_server_running.load()) return;

        std::cout << "[Embedded SFU] Stopping server..." << std::endl;
        g_sfu_server_running = false;

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