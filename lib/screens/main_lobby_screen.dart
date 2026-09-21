import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/audio_engine.dart';
import 'jam_room_screen.dart';
import 'chat_view.dart';
import 'lobby_screen.dart';
import 'login_screen.dart';

class JamRoom {
  final String id;
  final String name;
  final int roomId;
  final IconData icon;
  final String description;
  final bool isHost;
  final String remoteIp;

  JamRoom({
    required this.id,
    required this.name,
    required this.roomId,
    this.icon = Icons.music_note,
    this.description = '',
    this.isHost = true,
    this.remoteIp = '127.0.0.1',
  });
}

class MainLobbyScreen extends StatefulWidget {
  const MainLobbyScreen({super.key});

  @override
  State<MainLobbyScreen> createState() => _MainLobbyScreenState();
}

class _MainLobbyScreenState extends State<MainLobbyScreen> {
  final AudioEngine _audioEngine = AudioEngine();
  int _selectedChannel = 0; // 0: 합주실, 1: 채팅, 2: 일정 조율

  int _selectedRoomIndex = 0;
  final List<JamRoom> _rooms = [
    JamRoom(
      id: '1',
      name: '우리들만의 합주실',
      roomId: 1,
      icon: Icons.music_note,
      description: '메인 밴드 정기 합주 공간 (로컬 호스트)',
      isHost: true,
      remoteIp: '127.0.0.1',
    ),
  ];

  JamRoom get _currentRoom =>
      _rooms.isNotEmpty && _selectedRoomIndex < _rooms.length
          ? _rooms[_selectedRoomIndex]
          : JamRoom(id: '1', name: '우리들만의 합주실', roomId: 1);

  @override
  void initState() {
    super.initState();
    // 48kHz, 버퍼 128 (약 2.67ms) 기본 초기화
    _audioEngine.initialize(48000, 128);
    // 기본 첫 방이 호스트 모드이면 SFU 중계 서버 자동 가동
    if (_currentRoom.isHost) {
      _audioEngine.startHostSfu(port: 9999);
    }
  }

  void _toggleJamming() {
    if (_audioEngine.isStreaming) {
      _audioEngine.stop();
    } else {
      _audioEngine.start();
    }
  }

  @override
  void dispose() {
    _audioEngine.stop();
    _audioEngine.stopHostSfu();
    super.dispose();
  }

  void _openAudioSettingsDialog() {
    bool isHostMode = _currentRoom.isHost || _audioEngine.isSfuServerRunning;
    final ipController = TextEditingController(text: isHostMode ? '127.0.0.1' : _audioEngine.sfuIp);
    final portController = TextEditingController(text: _audioEngine.sfuPort.toString());
    final roomController = TextEditingController(text: _audioEngine.roomId.toString());
    final userController = TextEditingController(text: _audioEngine.userId.toString());
    int tempBuffer = _audioEngine.bufferSize;
    Map<String, String> localIps = {'tailscale': '', 'lan': '', 'loopback': '127.0.0.1'};

    _audioEngine.detectHostIps().then((ips) {
      localIps = ips;
    });

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
                  Text('오인페 및 SFU 서버 설정', style: TextStyle(color: Colors.white, fontSize: 18)),
                ],
              ),
              content: SingleChildScrollView(
                child: SizedBox(
                  width: 440,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 모드 선택 (방장 모드 vs 게스트 모드)
                      const Text(
                        'SFU 접속 방식 선택',
                        style: TextStyle(color: Color(0xFFB5BAC1), fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: ChoiceChip(
                              avatar: const Text('👑', style: TextStyle(fontSize: 12)),
                              label: const Text('내가 방장 (로컬 SFU)'),
                              selected: isHostMode,
                              selectedColor: const Color(0xFF5865F2),
                              labelStyle: TextStyle(
                                color: isHostMode ? Colors.white : const Color(0xFFB5BAC1),
                                fontSize: 12,
                                fontWeight: isHostMode ? FontWeight.bold : FontWeight.normal,
                              ),
                              onSelected: (val) {
                                if (val) {
                                  setDialogState(() {
                                    isHostMode = true;
                                    ipController.text = '127.0.0.1';
                                  });
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ChoiceChip(
                              avatar: const Icon(Icons.headphones, size: 14, color: Color(0xFFDBDEE1)),
                              label: const Text('게스트 (원격 SFU)'),
                              selected: !isHostMode,
                              selectedColor: const Color(0xFF5865F2),
                              labelStyle: TextStyle(
                                color: !isHostMode ? Colors.white : const Color(0xFFB5BAC1),
                                fontSize: 12,
                                fontWeight: !isHostMode ? FontWeight.bold : FontWeight.normal,
                              ),
                              onSelected: (val) {
                                if (val) {
                                  setDialogState(() {
                                    isHostMode = false;
                                    if (ipController.text == '127.0.0.1') {
                                      ipController.text = '';
                                    }
                                  });
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),

                      if (isHostMode) ...[
                        // 방장 모드 안내 및 서버 상태 패널
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E1F22),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFFFEE75C).withValues(alpha: 0.4)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    width: 8,
                                    height: 8,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: _audioEngine.isSfuServerRunning ? const Color(0xFF23A55A) : const Color(0xFFDA373C),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    _audioEngine.isSfuServerRunning
                                        ? '내장 SFU 중계 서버 실행 중 (피어: ${_audioEngine.sfuServerPeerCount}명)'
                                        : '내장 SFU 서버 대기/정지 상태',
                                    style: TextStyle(
                                      color: _audioEngine.isSfuServerRunning ? const Color(0xFF23A55A) : const Color(0xFFDA373C),
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const Spacer(),
                                  TextButton(
                                    onPressed: () {
                                      final port = int.tryParse(portController.text.trim()) ?? 9999;
                                      if (_audioEngine.isSfuServerRunning) {
                                        _audioEngine.stopHostSfu();
                                      } else {
                                        _audioEngine.startHostSfu(port: port);
                                      }
                                      setDialogState(() {});
                                    },
                                    child: Text(
                                      _audioEngine.isSfuServerRunning ? '서버 중지' : '서버 시작',
                                      style: const TextStyle(fontSize: 11, color: Color(0xFF5865F2)),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              if (localIps['tailscale']?.isNotEmpty ?? false)
                                Text(
                                  '• Tailscale 초대 IP: ${localIps['tailscale']}:${portController.text.trim()}',
                                  style: const TextStyle(color: Color(0xFFFEE75C), fontSize: 11),
                                ),
                              if (localIps['lan']?.isNotEmpty ?? false)
                                Text(
                                  '• 로컬 LAN IP: ${localIps['lan']}:${portController.text.trim()}',
                                  style: const TextStyle(color: Color(0xFF949BA4), fontSize: 11),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: portController,
                          keyboardType: TextInputType.number,
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                          decoration: const InputDecoration(
                            labelText: 'SFU UDP 포트 (기본 9999)',
                            hintText: '9999',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ] else ...[
                        // 게스트 모드: IP 직접 입력
                        Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: TextField(
                                controller: ipController,
                                style: const TextStyle(color: Colors.white, fontSize: 13),
                                decoration: const InputDecoration(
                                  labelText: '방장 Tailscale IP 또는 NAS IP',
                                  hintText: '예: 100.85.x.x 또는 192.168.0.x',
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
                      ],
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

                    if (isHostMode) {
                      _audioEngine.startHostSfu(port: port);
                      _audioEngine.configureSfu('127.0.0.1', port, room, user);
                    } else {
                      _audioEngine.stopHostSfu();
                      _audioEngine.configureSfu(ip, port, room, user);
                    }
                    _audioEngine.setBufferSize(tempBuffer);

                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(isHostMode
                            ? '방장 모드(내장 SFU 서버)가 활성화되었습니다. (루프백 0ms)'
                            : '게스트 모드로 SFU 서버 ($ip:$port)에 연결되었습니다.'),
                        backgroundColor: const Color(0xFF23A55A),
                        duration: const Duration(seconds: 3),
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

  void _selectRoom(int index) {
    if (index < 0 || index >= _rooms.length) return;
    setState(() {
      _selectedRoomIndex = index;
    });

    final room = _rooms[index];
    if (room.isHost) {
      _audioEngine.startHostSfu(port: _audioEngine.sfuPort);
      _audioEngine.configureSfu(
        '127.0.0.1',
        _audioEngine.sfuPort,
        room.roomId,
        _audioEngine.userId,
      );
    } else {
      _audioEngine.stopHostSfu();
      _audioEngine.configureSfu(
        room.remoteIp.isNotEmpty ? room.remoteIp : _audioEngine.sfuIp,
        _audioEngine.sfuPort,
        room.roomId,
        _audioEngine.userId,
      );
    }

    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(room.icon, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Text('\'${room.name}\' 합주실로 이동했습니다 (방 #${room.roomId} ${room.isHost ? '• 내가 방장' : ''})'),
          ],
        ),
        backgroundColor: const Color(0xFF5865F2),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _openCreateRoomDialog() {
    final nextRoomId = _rooms.fold<int>(0, (max, r) => r.roomId > max ? r.roomId : max) + 1;
    final nameController = TextEditingController(text: '새 합주실 #$nextRoomId');
    final idController = TextEditingController(text: nextRoomId.toString());
    final descController = TextEditingController();
    final remoteIpController = TextEditingController();
    bool isHost = true;
    IconData selectedIcon = Icons.music_note;

    final availableIcons = [
      Icons.music_note,
      Icons.headphones,
      Icons.piano,
      Icons.graphic_eq,
      Icons.album,
      Icons.speaker,
      Icons.mic,
      Icons.radio,
    ];

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
                  Icon(Icons.add_circle, color: Color(0xFF5865F2)),
                  SizedBox(width: 8),
                  Text('새 합주실 개설', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                ],
              ),
              content: SingleChildScrollView(
                child: SizedBox(
                  width: 440,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 방장 호스트 모드 여부 토글
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E1F22),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isHost ? const Color(0xFFFEE75C).withValues(alpha: 0.6) : const Color(0xFF383A40),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Text('👑 ', style: TextStyle(fontSize: 16)),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: const [
                                      Text(
                                        '내가 이 방의 SFU 호스트(방장) 되기',
                                        style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                                      ),
                                      Text(
                                        '내 컴퓨터에서 SFU 서버를 자동 실행하고 Tailscale로 친구를 초대합니다.',
                                        style: TextStyle(color: Color(0xFF949BA4), fontSize: 11),
                                      ),
                                    ],
                                  ),
                                ),
                                Switch(
                                  value: isHost,
                                  activeColor: const Color(0xFF5865F2),
                                  onChanged: (val) {
                                    setDialogState(() {
                                      isHost = val;
                                    });
                                  },
                                ),
                              ],
                            ),
                            if (!isHost) ...[
                              const SizedBox(height: 10),
                              TextField(
                                controller: remoteIpController,
                                style: const TextStyle(color: Colors.white, fontSize: 13),
                                decoration: const InputDecoration(
                                  labelText: '접속할 SFU 서버 IP (방장의 Tailscale IP)',
                                  hintText: '100.85.x.x 또는 192.168.0.x',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        '합주실 기본 정보',
                        style: TextStyle(color: Color(0xFFB5BAC1), fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: nameController,
                        style: const TextStyle(color: Colors.white, fontSize: 14),
                        decoration: const InputDecoration(
                          labelText: '합주실 이름',
                          hintText: '예: 주말 재즈 잼 세션, 락 밴드 합주실',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: idController,
                        keyboardType: TextInputType.number,
                        style: const TextStyle(color: Colors.white, fontSize: 14),
                        decoration: const InputDecoration(
                          labelText: 'SFU 방 번호 (Room ID)',
                          hintText: '1, 2, 3...',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        isHost ? '* 내 맥북의 내장 SFU 서버에 고유 채널 번호로 개설됩니다.' : '* 홈 NAS/원격 SFU 서버의 방 번호입니다.',
                        style: const TextStyle(color: Color(0xFF949BA4), fontSize: 11),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: descController,
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        decoration: const InputDecoration(
                          labelText: '합주실 소개 (선택)',
                          hintText: '예: 기타/베이스/드럼 세션 자유 잼',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        '합주실 아이콘 선택',
                        style: TextStyle(color: Color(0xFFB5BAC1), fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: availableIcons.map((iconData) {
                          final isSelected = selectedIcon == iconData;
                          return InkWell(
                            onTap: () => setDialogState(() => selectedIcon = iconData),
                            borderRadius: BorderRadius.circular(10),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: isSelected ? const Color(0xFF5865F2) : const Color(0xFF1E1F22),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: isSelected ? Colors.white : const Color(0xFF383A40),
                                  width: isSelected ? 2 : 1,
                                ),
                              ),
                              child: Icon(
                                iconData,
                                color: isSelected ? Colors.white : const Color(0xFF949BA4),
                                size: 22,
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('취소', style: TextStyle(color: Color(0xFF949BA4))),
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF5865F2)),
                  onPressed: () {
                    final name = nameController.text.trim();
                    if (name.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('합주실 이름을 입력해주세요.'),
                          backgroundColor: Color(0xFFF23F43),
                          duration: Duration(seconds: 2),
                        ),
                      );
                      return;
                    }
                    final roomId = int.tryParse(idController.text.trim()) ?? nextRoomId;

                    final newRoom = JamRoom(
                      id: DateTime.now().millisecondsSinceEpoch.toString(),
                      name: name,
                      roomId: roomId,
                      icon: selectedIcon,
                      description: descController.text.trim(),
                      isHost: isHost,
                      remoteIp: isHost ? '127.0.0.1' : remoteIpController.text.trim(),
                    );

                    setState(() {
                      _rooms.add(newRoom);
                      _selectedRoomIndex = _rooms.length - 1;
                    });

                    if (isHost) {
                      _audioEngine.startHostSfu(port: _audioEngine.sfuPort);
                      _audioEngine.configureSfu(
                        '127.0.0.1',
                        _audioEngine.sfuPort,
                        newRoom.roomId,
                        _audioEngine.userId,
                      );
                    } else {
                      _audioEngine.stopHostSfu();
                      _audioEngine.configureSfu(
                        newRoom.remoteIp.isNotEmpty ? newRoom.remoteIp : _audioEngine.sfuIp,
                        _audioEngine.sfuPort,
                        newRoom.roomId,
                        _audioEngine.userId,
                      );
                    }

                    Navigator.pop(context);

                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(isHost
                            ? '\'$name\' 합주실이 개설되었습니다! (방 번호: #$roomId • 내 SFU 서버 가동)'
                            : '\'$name\' 합주실이 개설되었습니다! (방 번호: #$roomId)'),
                        backgroundColor: const Color(0xFF23A55A),
                        duration: const Duration(seconds: 3),
                      ),
                    );
                  },
                  icon: const Icon(Icons.check, color: Colors.white, size: 18),
                  label: const Text('합주실 개설', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _deleteCurrentRoom() {
    if (_rooms.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('최소 1개의 합주실은 유지되어야 합니다.'),
          backgroundColor: Color(0xFFF23F43),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    final current = _currentRoom;
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF2B2D31),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          title: const Text('합주실 닫기', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          content: Text(
            '\'${current.name}\' 합주실을 닫고 목록에서 제거하시겠습니까?',
            style: const TextStyle(color: Color(0xFFDBDEE1)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('취소', style: TextStyle(color: Color(0xFF949BA4))),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFF23F43)),
              onPressed: () {
                setState(() {
                  _rooms.removeAt(_selectedRoomIndex);
                  _selectedRoomIndex = _selectedRoomIndex.clamp(0, _rooms.length - 1);
                });
                _audioEngine.configureSfu(
                  _audioEngine.sfuIp,
                  _audioEngine.sfuPort,
                  _currentRoom.roomId,
                  _audioEngine.userId,
                );
                Navigator.pop(context);
                ScaffoldMessenger.of(context).hideCurrentSnackBar();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('\'${current.name}\' 합주실이 닫혔습니다.'),
                    backgroundColor: const Color(0xFF4E5058),
                    duration: const Duration(seconds: 2),
                  ),
                );
              },
              child: const Text('삭제', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  String get _currentUserName {
    try {
      if (Firebase.apps.isNotEmpty) {
        final user = FirebaseAuth.instance.currentUser;
        if (user?.displayName != null && user!.displayName!.trim().isNotEmpty) {
          return user.displayName!;
        }
        if (user?.email != null && user!.email!.trim().isNotEmpty) {
          return user.email!.split('@').first;
        }
      }
    } catch (_) {}
    return '의진';
  }

  Future<void> _confirmLogout() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF2B2D31),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          title: Row(
            children: const [
              Icon(Icons.logout, color: Color(0xFFF23F43)),
              SizedBox(width: 8),
              Text('로그아웃', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
            ],
          ),
          content: const Text(
            '정말 합주실에서 로그아웃하시겠습니까?\n저장된 로그인 세션이 해제됩니다.',
            style: TextStyle(color: Color(0xFFDBDEE1), fontSize: 14),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('취소', style: TextStyle(color: Color(0xFF949BA4))),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFF23F43)),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('로그아웃', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );

    if (confirmed == true) {
      if (_audioEngine.isStreaming) {
        _audioEngine.stop();
      }
      try {
        if (Firebase.apps.isNotEmpty) {
          await FirebaseAuth.instance.signOut();
        }
      } catch (_) {}
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (context) => const LoginScreen()),
        (route) => false,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('정상적으로 로그아웃되었습니다.'),
          backgroundColor: Color(0xFF4E5058),
          duration: Duration(seconds: 2),
        ),
      );
    }
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
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
                          children: [
                            for (int i = 0; i < _rooms.length; i++) ...[
                              _buildServerIcon(
                                icon: _rooms[i].icon,
                                isActive: _selectedRoomIndex == i,
                                tooltip: '${_rooms[i].name} (방 #${_rooms[i].roomId})',
                                onTap: () => _selectRoom(i),
                              ),
                              const SizedBox(height: 8),
                            ],
                            const Divider(color: Color(0xFF35363C), indent: 16, endIndent: 16),
                            const SizedBox(height: 8),
                            _buildServerIcon(
                              icon: Icons.add,
                              isActive: false,
                              tooltip: '새 합주실 개설',
                              onTap: _openCreateRoomDialog,
                              isAddButton: true,
                            ),
                          ],
                        ),
                      ),
                    ),
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
                      child: PopupMenuButton<String>(
                        color: const Color(0xFF2B2D31),
                        offset: const Offset(0, 48),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        tooltip: '합주실 옵션',
                        onSelected: (value) {
                          if (value == 'create') {
                            _openCreateRoomDialog();
                          } else if (value == 'settings') {
                            _openAudioSettingsDialog();
                          } else if (value == 'delete') {
                            _deleteCurrentRoom();
                          } else if (value == 'logout') {
                            _confirmLogout();
                          }
                        },
                        itemBuilder: (context) => [
                          PopupMenuItem(
                            value: 'create',
                            child: Row(
                              children: const [
                                Icon(Icons.add_circle_outline, color: Color(0xFF5865F2), size: 18),
                                SizedBox(width: 8),
                                Text('새 합주실 개설', style: TextStyle(color: Colors.white, fontSize: 13)),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: 'settings',
                            child: Row(
                              children: const [
                                Icon(Icons.tune, color: Color(0xFF949BA4), size: 18),
                                SizedBox(width: 8),
                                Text('오인페 및 SFU 설정', style: TextStyle(color: Colors.white, fontSize: 13)),
                              ],
                            ),
                          ),
                          if (_rooms.length > 1)
                            PopupMenuItem(
                              value: 'delete',
                              child: Row(
                                children: const [
                                  Icon(Icons.delete_outline, color: Color(0xFFF23F43), size: 18),
                                  SizedBox(width: 8),
                                  Text('현재 합주실 닫기', style: TextStyle(color: Color(0xFFF23F43), fontSize: 13)),
                                ],
                              ),
                            ),
                          const PopupMenuDivider(height: 1),
                          PopupMenuItem(
                            value: 'logout',
                            child: Row(
                              children: const [
                                Icon(Icons.logout, color: Color(0xFFF23F43), size: 18),
                                SizedBox(width: 8),
                                Text('로그아웃', style: TextStyle(color: Color(0xFFF23F43), fontSize: 13)),
                              ],
                            ),
                          ),
                        ],
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                _currentRoom.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                  fontSize: 14,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const Icon(Icons.keyboard_arrow_down, color: Color(0xFF949BA4), size: 18),
                          ],
                        ),
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
                              CircleAvatar(
                                radius: 18,
                                backgroundColor: const Color(0xFF5865F2),
                                child: Text(
                                  _currentUserName.isNotEmpty ? _currentUserName[0].toUpperCase() : '의',
                                  style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.bold),
                                ),
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
                                Text(
                                  '$_currentUserName (나)',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white),
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
                          IconButton(
                            icon: const Icon(Icons.logout, color: Color(0xFF949BA4), size: 18),
                            onPressed: _confirmLogout,
                            tooltip: '로그아웃',
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
          roomName: _currentRoom.name,
          isHost: _currentRoom.isHost,
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

  Widget _buildServerIcon({
    required IconData icon,
    required bool isActive,
    required String tooltip,
    required VoidCallback onTap,
    bool isAddButton = false,
  }) {
    return Tooltip(
      message: tooltip,
      preferBelow: false,
      child: SizedBox(
        width: 72,
        height: 48,
        child: Stack(
          alignment: Alignment.centerLeft,
          children: [
            // Discord 스타일 활성화 인디케이터 (왼쪽 흰색 필)
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 4,
              height: isActive ? 40 : 0,
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.only(
                  topRight: Radius.circular(4),
                  bottomRight: Radius.circular(4),
                ),
              ),
            ),
            Center(
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(isActive ? 16 : 24),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: isActive
                        ? const Color(0xFF5865F2)
                        : (isAddButton ? const Color(0xFF2B2D31) : const Color(0xFF313338)),
                    borderRadius: BorderRadius.circular(isActive ? 16 : 24),
                    border: isAddButton
                        ? Border.all(color: const Color(0xFF23A55A).withValues(alpha: 0.5), width: 1.5)
                        : null,
                  ),
                  child: Icon(
                    icon,
                    color: isAddButton
                        ? const Color(0xFF23A55A)
                        : (isActive ? Colors.white : const Color(0xFFDBDEE1)),
                    size: 24,
                  ),
                ),
              ),
            ),
          ],
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: isSelected ? const Color(0xFF404249) : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
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
    ),
  );
  }
}