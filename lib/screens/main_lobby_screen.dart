import 'package:flutter/material.dart';
import '../services/audio_engine.dart';
import 'jam_room_screen.dart';
import 'chat_view.dart';
import 'lobby_screen.dart';

class MainLobbyScreen extends StatefulWidget {
  const MainLobbyScreen({super.key});

  @override
  State<MainLobbyScreen> createState() => _MainLobbyScreenState();
}

class _MainLobbyScreenState extends State<MainLobbyScreen> {
  final AudioEngine _audioEngine = AudioEngine();
  int _selectedChannel = 0; // 0: 합주실, 1: 채팅, 2: 일정 조율

  @override
  void initState() {
    super.initState();
    // 48kHz, 버퍼 128 (약 2.67ms) 기본 초기화
    _audioEngine.initialize(48000, 128);
  }

  void _toggleJamming() {
    if (_audioEngine.isStreaming) {
      _audioEngine.stop();
    } else {
      _audioEngine.start();
    }
  }

  void _openAudioSettingsDialog() {
    final ipController = TextEditingController(text: _audioEngine.sfuIp);
    final portController = TextEditingController(text: _audioEngine.sfuPort.toString());
    final roomController = TextEditingController(text: _audioEngine.roomId.toString());
    final userController = TextEditingController(text: _audioEngine.userId.toString());
    int tempBuffer = _audioEngine.bufferSize;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF2B2D31),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              title: Row(
                children: const [
                  Icon(Icons.tune, color: Color(0xFF5865F2)),
                  SizedBox(width: 8),
                  Text('오인페 및 홈 NAS SFU 설정', style: TextStyle(color: Colors.white, fontSize: 18)),
                ],
              ),
              content: SingleChildScrollView(
                child: SizedBox(
                  width: 420,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '중계 서버 (홈 NAS)',
                        style: TextStyle(color: Color(0xFFB5BAC1), fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: TextField(
                              controller: ipController,
                              style: const TextStyle(color: Colors.white, fontSize: 13),
                              decoration: const InputDecoration(
                                labelText: 'NAS IP / DDNS',
                                hintText: '192.168.0.50 또는 myjam.synology.me',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 2,
                            child: TextField(
                              controller: portController,
                              keyboardType: TextInputType.number,
                              style: const TextStyle(color: Colors.white, fontSize: 13),
                              decoration: const InputDecoration(
                                labelText: 'UDP 포트',
                                hintText: '9999',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: roomController,
                              keyboardType: TextInputType.number,
                              style: const TextStyle(color: Colors.white, fontSize: 13),
                              decoration: const InputDecoration(
                                labelText: '방 번호 (Room ID)',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: userController,
                              keyboardType: TextInputType.number,
                              style: const TextStyle(color: Colors.white, fontSize: 13),
                              decoration: const InputDecoration(
                                labelText: '내 유저 ID',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      const Text(
                        '오디오 인터페이스 버퍼 사이즈 (초저지연)',
                        style: TextStyle(color: Color(0xFFB5BAC1), fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [64, 128, 256].map((size) {
                          final selected = tempBuffer == size;
                          return ChoiceChip(
                            label: Text('$size samples (${(size / 48.0).toStringAsFixed(1)}ms)'),
                            selected: selected,
                            onSelected: (val) {
                              if (val) setDialogState(() => tempBuffer = size);
                            },
                            selectedColor: const Color(0xFF5865F2),
                            labelStyle: TextStyle(
                              color: selected ? Colors.white : const Color(0xFFB5BAC1),
                              fontSize: 12,
                            ),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E1F22),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              _audioEngine.isNativeLoaded ? Icons.check_circle : Icons.info_outline,
                              color: _audioEngine.isNativeLoaded ? const Color(0xFF23A55A) : Colors.amber,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _audioEngine.isNativeLoaded
                                    ? 'C++ 네이티브 오디오 코어 연결됨 (ASIO / CoreAudio 직결)'
                                    : '시뮬레이션 모드 (C++ 공유 라이브러리 빌드 대기)',
                                style: TextStyle(
                                  color: _audioEngine.isNativeLoaded ? const Color(0xFF23A55A) : Colors.amber,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('닫기', style: TextStyle(color: Color(0xFF949BA4))),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF5865F2)),
                  onPressed: () {
                    final ip = ipController.text.trim();
                    final port = int.tryParse(portController.text.trim()) ?? 9999;
                    final room = int.tryParse(roomController.text.trim()) ?? 1;
                    final user = int.tryParse(userController.text.trim()) ?? 101;

                    _audioEngine.configureSfu(ip, port, room, user);
                    _audioEngine.setBufferSize(tempBuffer);

                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('오인페 및 SFU 설정이 적용되었습니다.'),
                        backgroundColor: Color(0xFF23A55A),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                  child: const Text('설정 저장', style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _audioEngine,
      builder: (context, _) {
        return Scaffold(
          backgroundColor: const Color(0xFF313338),
          body: Row(
            children: [
              // 1. 서버 목록 바 (가장 왼쪽 좁은 72px 바)
              Container(
                width: 72,
                color: const Color(0xFF1E1F22),
                child: Column(
                  children: [
                    const SizedBox(height: 12),
                    _buildServerIcon(Icons.music_note, true, '우리들만의 합주실'),
                    const SizedBox(height: 8),
                    const Divider(color: Color(0xFF35363C), indent: 16, endIndent: 16),
                    const SizedBox(height: 8),
                    _buildServerIcon(Icons.add, false, '새 합주실 개설'),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.settings, color: Color(0xFF949BA4)),
                      onPressed: _openAudioSettingsDialog,
                      tooltip: '오인페 / NAS 설정',
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),

              // 2. 채널 및 내 프로필 바 (240px)
              Container(
                width: 240,
                color: const Color(0xFF2B2D31),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 서버 헤더
                    Container(
                      height: 48,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      alignment: Alignment.centerLeft,
                      decoration: const BoxDecoration(
                        border: Border(bottom: BorderSide(color: Color(0xFF1F2023))),
                      ),
                      child: Row(
                        children: const [
                          Expanded(
                            child: Text(
                              '우리들만의 합주실',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                                fontSize: 14,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Icon(Icons.keyboard_arrow_down, color: Color(0xFF949BA4), size: 18),
                        ],
                      ),
                    ),

                    // 채널 카테고리 & 목록
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                        children: [
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                            child: Text(
                              '오디오 채널',
                              style: TextStyle(
                                color: Color(0xFF949BA4),
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                          _buildChannelTile(
                            icon: Icons.volume_up,
                            title: '합주실 세션 (Live)',
                            index: 0,
                            isLive: _audioEngine.isStreaming,
                          ),
                          const SizedBox(height: 16),
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                            child: Text(
                              '소통 및 조율',
                              style: TextStyle(
                                color: Color(0xFF949BA4),
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                          _buildChannelTile(
                            icon: Icons.chat_bubble_outline,
                            title: '실시간 채팅 & 링크',
                            index: 1,
                          ),
                          _buildChannelTile(
                            icon: Icons.calendar_today,
                            title: '합주 일정 조율 (투표)',
                            index: 2,
                          ),
                        ],
                      ),
                    ),

                    // 하단 내 프로필 & 오인페 상태 영역
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                      color: const Color(0xFF232428),
                      child: Row(
                        children: [
                          Stack(
                            alignment: Alignment.bottomRight,
                            children: [
                              const CircleAvatar(
                                radius: 18,
                                backgroundColor: Color(0xFF5865F2),
                                child: Text('의진', style: TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.bold)),
                              ),
                              Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                  color: _audioEngine.isStreaming ? const Color(0xFF23A55A) : const Color(0xFF80848E),
                                  shape: BoxShape.circle,
                                  border: Border.all(color: const Color(0xFF232428), width: 1.5),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  '의진 (나)',
                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  _audioEngine.isStreaming ? 'UDP 스트리밍 중' : '오인페 대기중',
                                  style: TextStyle(
                                    color: _audioEngine.isStreaming ? const Color(0xFF23A55A) : const Color(0xFF949BA4),
                                    fontSize: 10,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: Icon(
                              _audioEngine.isStreaming ? Icons.mic : Icons.mic_off,
                              color: _audioEngine.isStreaming ? const Color(0xFF23A55A) : const Color(0xFFF23F43),
                              size: 20,
                            ),
                            onPressed: _toggleJamming,
                            tooltip: _audioEngine.isStreaming ? '합주 송출 중지' : '합주 송출 시작',
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // 3. 메인 콘텐츠 영역 (동적 스위칭)
              Expanded(
                child: Container(
                  color: const Color(0xFF313338),
                  child: _buildMainContent(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMainContent() {
    switch (_selectedChannel) {
      case 0:
        return JamRoomScreen(
          onToggleJam: _toggleJamming,
          isJamming: _audioEngine.isStreaming,
          onOpenSettings: _openAudioSettingsDialog,
        );
      case 1:
        return const ChatView();
      case 2:
        return const LobbyScreen();
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildServerIcon(IconData icon, bool isActive, String tooltip) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: () {},
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: isActive ? const Color(0xFF5865F2) : const Color(0xFF313338),
            borderRadius: BorderRadius.circular(isActive ? 16 : 24),
          ),
          child: Icon(icon, color: Colors.white, size: 24),
        ),
      ),
    );
  }

  Widget _buildChannelTile({
    required IconData icon,
    required String title,
    required int index,
    bool isLive = false,
  }) {
    final bool isSelected = _selectedChannel == index;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: isSelected ? const Color(0xFF404249) : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
      ),
      child: ListTile(
        leading: Icon(
          icon,
          color: isSelected ? Colors.white : const Color(0xFF80848E),
          size: 18,
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  color: isSelected ? Colors.white : const Color(0xFF949BA4),
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (isLive)
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: Color(0xFF23A55A),
                  shape: BoxShape.circle,
                ),
              ),
          ],
        ),
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
        onTap: () => setState(() => _selectedChannel = index),
      ),
    );
  }
}