#include <iostream>
#include <vector>
#include <unordered_map>
#include <chrono>
#include <cstring>
#include <atomic>
#include <thread>
#include <csignal>

#ifdef _WIN32
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

#include "protocol.h"

static std::atomic<bool> g_running{true};

void signal_handler(int signum) {
    std::cout << "\n[SFU] Stopping server gracefully (signal " << signum << ")..." << std::endl;
    g_running = false;
}

// 참여자 세션 정보
struct PeerInfo {
    uint16_t user_id;
    sockaddr_in address;
    std::chrono::steady_clock::time_point last_seen;
};

// 주소 비교 헬퍼
bool is_same_address(const sockaddr_in& a, const sockaddr_in& b) {
    return a.sin_addr.s_addr == b.sin_addr.s_addr && a.sin_port == b.sin_port;
}

int main(int argc, char* argv[]) {
    int port = 9999;
    if (argc > 1) {
        port = std::atoi(argv[1]);
    }

    std::signal(SIGINT, signal_handler);
    std::signal(SIGTERM, signal_handler);

#ifdef _WIN32
    WSADATA wsaData;
    if (WSAStartup(MAKEWORD(2, 2), &wsaData) != 0) {
        std::cerr << "[SFU Error] WSAStartup failed" << std::endl;
        return 1;
    }
#endif

    SOCKET sockfd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (sockfd == INVALID_SOCKET) {
        std::cerr << "[SFU Error] Failed to create UDP socket" << std::endl;
        return 1;
    }

    // 소켓 수신/송신 버퍼 확장 (저지연 드롭 방지)
    int buffer_size = 1024 * 1024; // 1MB
    setsockopt(sockfd, SOL_SOCKET, SO_RCVBUF, (const char*)&buffer_size, sizeof(buffer_size));
    setsockopt(sockfd, SOL_SOCKET, SO_SNDBUF, (const char*)&buffer_size, sizeof(buffer_size));

    // Non-blocking 또는 짧은 타임아웃 설정
#ifdef _WIN32
    DWORD timeout_ms = 50;
    setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, (const char*)&timeout_ms, sizeof(timeout_ms));
#else
    struct timeval tv;
    tv.tv_sec = 0;
    tv.tv_usec = 50000; // 50ms
    setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, (const char*)&tv, sizeof(tv));
#endif

    sockaddr_in server_addr{};
    server_addr.sin_family = AF_INET;
    server_addr.sin_addr.s_addr = INADDR_ANY;
    server_addr.sin_port = htons(port);

    if (bind(sockfd, (struct sockaddr*)&server_addr, sizeof(server_addr)) == SOCKET_ERROR) {
        std::cerr << "[SFU Error] Failed to bind to port " << port << std::endl;
        closesocket(sockfd);
        return 1;
    }

    std::cout << "====================================================\n";
    std::cout << "   SyncRoom Low-Latency UDP SFU Relay Server\n";
    std::cout << "   Listening on UDP port: " << port << "\n";
    std::cout << "   Ideal for Home NAS Deployment (Gyeonggi <-> Seoul)\n";
    std::cout << "====================================================\n" << std::endl;

    // Room ID -> 참여자 목록
    std::unordered_map<uint16_t, std::vector<PeerInfo>> rooms;

    // 통계용 변수
    uint64_t total_packets_in = 0;
    uint64_t total_bytes_in = 0;
    uint64_t total_packets_fwd = 0;

    auto last_stats_time = std::chrono::steady_clock::now();
    uint8_t recv_buffer[8192];

    while (g_running) {
        sockaddr_in client_addr{};
        socklen_t addr_len = sizeof(client_addr);

        int bytes_received = recvfrom(
            sockfd,
            (char*)recv_buffer,
            sizeof(recv_buffer),
            0,
            (struct sockaddr*)&client_addr,
            &addr_len
        );

        auto now = std::chrono::steady_clock::now();

        if (bytes_received >= (int)sizeof(AudioPacketHeader)) {
            auto* header = reinterpret_cast<AudioPacketHeader*>(recv_buffer);

            // 매직 넘버 검증
            if (header->magic == SYNC_MAGIC) {
                total_packets_in++;
                total_bytes_in += bytes_received;
                uint16_t room_id = header->room_id;
                uint16_t user_id = header->user_id;

                auto& peer_list = rooms[room_id];

                // 참여자 정보 등록 또는 갱신
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
                    std::cout << "[Room " << room_id << "] New peer connected: User " << user_id 
                              << " (" << ip_str << ":" << ntohs(client_addr.sin_port) << ")" << std::endl;
                }

                // 패킷 타입별 처리
                if (header->packet_type == PACKET_TYPE_AUDIO) {
                    // Selective Forwarding: 동일 방의 타 참여자들에게만 즉시 중계
                    for (const auto& peer : peer_list) {
                        if (peer.user_id != user_id) {
                            sendto(
                                sockfd,
                                (const char*)recv_buffer,
                                bytes_received,
                                0,
                                (struct sockaddr*)&peer.address,
                                sizeof(peer.address)
                            );
                            total_packets_fwd++;
                        }
                    }
                } else if (header->packet_type == PACKET_TYPE_PING) {
                    // 클라이언트 RTT 측정용 에코 응답 (PONG)
                    header->packet_type = PACKET_TYPE_PONG;
                    sendto(
                        sockfd,
                        (const char*)recv_buffer,
                        sizeof(AudioPacketHeader),
                        0,
                        (struct sockaddr*)&client_addr,
                        sizeof(client_addr)
                    );
                } else if (header->packet_type == PACKET_TYPE_LEAVE) {
                    // 퇴장 처리
                    for (auto it = peer_list.begin(); it != peer_list.end(); ) {
                        if (it->user_id == user_id) {
                            std::cout << "[Room " << room_id << "] Peer disconnected: User " << user_id << std::endl;
                            it = peer_list.erase(it);
                        } else {
                            ++it;
                        }
                    }
                }
            }
        }

        // 3초마다 타임아웃 세션 정리 및 통계 출력
        if (std::chrono::duration_cast<std::chrono::seconds>(now - last_stats_time).count() >= 3) {
            last_stats_time = now;
            size_t total_active_peers = 0;

            for (auto it = rooms.begin(); it != rooms.end(); ) {
                auto& peer_list = it->second;
                for (auto p_it = peer_list.begin(); p_it != peer_list.end(); ) {
                    auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(now - p_it->last_seen).count();
                    if (elapsed > 5) { // 5초간 무응답 시 정리
                        std::cout << "[Room " << it->first << "] Peer timed out: User " << p_it->user_id << std::endl;
                        p_it = peer_list.erase(p_it);
                    } else {
                        ++p_it;
                    }
                }
                if (peer_list.empty()) {
                    it = rooms.erase(it);
                } else {
                    total_active_peers += peer_list.size();
                    ++it;
                }
            }

            if (total_packets_in > 0 || total_active_peers > 0) {
                double kb_in = (total_bytes_in / 1024.0) / 3.0;
                std::cout << "[SFU Stats] Rooms: " << rooms.size()
                          << " | Active Peers: " << total_active_peers
                          << " | Rx: " << (total_packets_in / 3) << " pkts/s (" << kb_in << " KB/s)"
                          << " | Fwd: " << (total_packets_fwd / 3) << " pkts/s"
                          << std::endl;
                total_packets_in = 0;
                total_bytes_in = 0;
                total_packets_fwd = 0;
            }
        }
    }

    std::cout << "[SFU] Closing socket and shutting down..." << std::endl;
    closesocket(sockfd);
#ifdef _WIN32
    WSACleanup();
#endif
    return 0;
}
