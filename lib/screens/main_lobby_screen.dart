import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/audio_engine.dart';
import '../services/upnp_service.dart';
import 'jam_room_screen.dart';
import 'chat_view.dart';
import 'lobby_screen.dart';
import 'login_screen.dart';
import '../services/deep_link_service.dart';
import '../services/user_service.dart';

class JamRoom {
  final String id;
  final String name;
  final int roomId;
  final IconData icon;
  final String description;
  final String hostUid;
  final String hostName;
  final String hostPublicIp;
  final String hostTailscaleIp;
  final String hostLanIp;
  final String hostZeroTierIp;
  final int port;
  final bool isHost;
  final bool isUpnpActive;
  final String remoteIp;
  final String? ztNetworkId;

  JamRoom({
    required this.id,
    required this.name,
    required this.roomId,
    this.icon = Icons.music_note,
    this.description = '',
    this.hostUid = '',
    this.hostName = '방장',
    this.hostPublicIp = '',
    this.hostTailscaleIp = '',
    this.hostLanIp = '',
    this.hostZeroTierIp = '',
    this.port = 9999,
    this.isHost = true,
    this.isUpnpActive = false,
    this.remoteIp = '127.0.0.1',
    this.ztNetworkId,
  });

  String get effectivePublicIp {
    if (hostZeroTierIp.isNotEmpty) return hostZeroTierIp;
    if (remoteIp.isNotEmpty && remoteIp != '127.0.0.1') return remoteIp;
    if (hostPublicIp.isNotEmpty) return hostPublicIp;
    if (hostLanIp.isNotEmpty) return hostLanIp;
    return hostTailscaleIp;
  }

  static IconData iconFromCode(int code) {
    if (code == Icons.music_note.codePoint) return Icons.music_note;
    if (code == Icons.headphones.codePoint) return Icons.headphones;
    if (code == Icons.piano.codePoint) return Icons.piano;
    if (code == Icons.graphic_eq.codePoint) return Icons.graphic_eq;
    if (code == Icons.album.codePoint) return Icons.album;
    if (code == Icons.speaker.codePoint) return Icons.speaker;
    if (code == Icons.mic.codePoint) return Icons.mic;
    if (code == Icons.radio.codePoint) return Icons.radio;
    return Icons.music_note;
  }

  factory JamRoom.fromFirestore(
    DocumentSnapshot doc,
    String currentUserId, {
    String currentUserName = '',
    bool forceHost = false,
  }) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    final hostUid = (data['hostUid'] as String?) ?? '';
    final hostName = (data['hostName'] as String?) ?? '방장';

    // 딥링크에서 명시적으로 게스트(isHost=false)로 진입한 경우 절대 방장으로 판단하지 않음
    final deepLink = DeepLinkService().currentSession;
    final isExplicitGuest = deepLink != null && !deepLink.isHost;

    final isHost = isExplicitGuest
        ? false
        : (forceHost ||
            (hostUid.isNotEmpty && currentUserId.isNotEmpty
                ? (hostUid == currentUserId)
                : (currentUserId.isNotEmpty && hostName == currentUserName)));
    final iconCode = (data['iconCode'] as int?) ?? Icons.music_note.codePoint;
    final publicIp =
        (data['hostPublicIp'] as String?) ??
        (data['hostTailscaleIp'] as String?) ??
        '';
    final tailscale = (data['hostTailscaleIp'] as String?) ?? '';
    final lan = (data['hostLanIp'] as String?) ?? '';
    final ztIp = (data['hostZeroTierIp'] as String?) ?? '';
    final port = (data['port'] as int?) ?? 9999;
    final isUpnp = (data['isUpnpActive'] as bool?) ?? false;
    final ztNetId = (data['ztNetworkId'] as String?) ?? '';

    final remote = ztIp.isNotEmpty
        ? ztIp
        : (publicIp.isNotEmpty ? publicIp : lan);

    return JamRoom(
      id: doc.id,
      name: (data['name'] as String?) ?? '합주실',
      roomId: (data['roomId'] as int?) ?? 1,
      icon: iconFromCode(iconCode),
      description: (data['description'] as String?) ?? '',
      hostUid: hostUid,
      hostName: hostName,
      hostPublicIp: publicIp,
      hostTailscaleIp: tailscale,
      hostLanIp: lan,
      hostZeroTierIp: ztIp,
      port: port,
      isHost: isHost,
      isUpnpActive: isUpnp,
      remoteIp: isHost ? '127.0.0.1' : remote,
      ztNetworkId: ztNetId.isNotEmpty ? ztNetId : null,
    );
  }
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
      name: '합주실',
      roomId: 1,
      icon: Icons.music_note,
      description: '합주 공간 (로컬 호스트)',
      isHost: true,
      remoteIp: '127.0.0.1',
    ),
  ];

  StreamSubscription<QuerySnapshot>? _roomsSub;

  JamRoom get _currentRoom =>
      (_rooms.isNotEmpty &&
          _selectedRoomIndex >= 0 &&
          _selectedRoomIndex < _rooms.length)
      ? _rooms[_selectedRoomIndex]
      : (_rooms.isNotEmpty
            ? _rooms.first
            : JamRoom(id: '1', name: '합주실', roomId: 1));

  @override
  void initState() {
    super.initState();
    final deepLink = DeepLinkService().currentSession;
    final currentUid = deepLink?.userId ??
        (UserService().uid.isNotEmpty
            ? UserService().uid
            : (Firebase.apps.isNotEmpty
                ? (FirebaseAuth.instance.currentUser?.uid ?? '')
                : ''));
    _audioEngine.assignUniqueUserId(currentUid);
    _audioEngine.initialize(48000, 128);

    // 디스코드 딥링크 세션이 존재하는 경우 초기 방 설정
    if (deepLink != null) {
      final docId = 'discord-room-${deepLink.roomId}';
      if (deepLink.isHost) {
        final hostName = deepLink.userName.isNotEmpty ? deepLink.userName : _currentUserName;
        _rooms[0] = JamRoom(
          id: docId,
          name: deepLink.roomName,
          roomId: deepLink.roomId,
          icon: Icons.music_note,
          description: '디스코드 개설 합주실',
          hostUid: currentUid,
          hostName: hostName,
          port: deepLink.port,
          isHost: true,
          ztNetworkId: deepLink.ztNetworkId,
          remoteIp: '127.0.0.1',
        );

        // 방장이 딥링크로 접속한 경우 즉시 Firebase Firestore에 방 등록/업데이트!
        if (Firebase.apps.isNotEmpty) {
          UpnpService().fetchPublicIpFromWeb().then((publicIp) {
            final lanIp = UpnpService().localLanIp;
            FirebaseFirestore.instance.collection('jam_rooms').doc(docId).set({
              'name': deepLink.roomName,
              'roomId': deepLink.roomId,
              'iconCode': Icons.music_note.codePoint,
              'description': '디스코드 개설 합주실 (방장: $hostName)',
              'hostUid': currentUid,
              'hostName': hostName,
              'hostPublicIp': publicIp,
              'hostLanIp': lanIp,
              'port': deepLink.port,
              'ztNetworkId': deepLink.ztNetworkId ?? '',
              'createdAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
          });
        }
      } else {
        _rooms[0] = JamRoom(
          id: docId,
          name: deepLink.roomName,
          roomId: deepLink.roomId,
          icon: Icons.music_note,
          description: '디스코드 참여 합주실',
          hostName: '방장',
          hostPublicIp: deepLink.hostIp ?? '',
          port: deepLink.port,
          isHost: false,
          ztNetworkId: deepLink.ztNetworkId,
          remoteIp: (deepLink.hostIp != null && deepLink.hostIp!.isNotEmpty)
              ? deepLink.hostIp!
              : '127.0.0.1',
        );
      }
    }

    _listenToRooms();
    if (_currentRoom.isHost) {
      _audioEngine.startHostSfu(port: _currentRoom.port);
      UpnpService().openPort(port: _currentRoom.port).then((_) {
        if (mounted) {
          setState(() {});
          if (Firebase.apps.isNotEmpty && deepLink != null && deepLink.isHost) {
            final docId = 'discord-room-${deepLink.roomId}';
            FirebaseFirestore.instance.collection('jam_rooms').doc(docId).set({
              'hostPublicIp': UpnpService().publicIp,
              'hostLanIp': UpnpService().localLanIp,
              'isUpnpActive': UpnpService().isPortMapped,
            }, SetOptions(merge: true));
          }
        }
      });
    } else {
      if (_audioEngine.isSfuServerRunning) {
        _audioEngine.stopHostSfu();
      }
      final remote = _currentRoom.effectivePublicIp;
      _audioEngine.configureSfu(
        remote,
        _currentRoom.port,
        _currentRoom.roomId,
        _audioEngine.userId,
      );
      UpnpService().fetchPublicIpFromWeb().then((_) {
        if (mounted) setState(() {});
      });
    }
  }

  void _listenToRooms() {
    try {
      if (Firebase.apps.isNotEmpty) {
        final deepLink = DeepLinkService().currentSession;
        final currentUid = deepLink?.userId ??
            (UserService().uid.isNotEmpty
                ? UserService().uid
                : (FirebaseAuth.instance.currentUser?.uid ?? ''));
        _roomsSub = FirebaseFirestore.instance
            .collection('jam_rooms')
            .orderBy('createdAt', descending: false)
            .snapshots()
            .listen(
              (snapshot) {
                if (snapshot.docs.isNotEmpty) {
                  final loaded = snapshot.docs
                      .map((d) => JamRoom.fromFirestore(
                            d,
                            currentUid,
                            currentUserName: _currentUserName,
                            forceHost: deepLink?.isHost == true,
                          ))
                      .toList();
                  if (mounted) {
                    setState(() {
                      _rooms.clear();
                      _rooms.addAll(loaded);

                      // 딥링크 방이 있으면 해당 방으로 _selectedRoomIndex 자동 전환!
                      if (deepLink != null) {
                        final docId = 'discord-room-${deepLink.roomId}';
                        final matchIdx = _rooms.indexWhere(
                            (r) => r.id == docId || r.roomId == deepLink.roomId);
                        if (matchIdx != -1) {
                          _selectedRoomIndex = matchIdx;
                        }
                      }

                      if (_rooms.isEmpty) {
                        _selectedRoomIndex = -1;
                      } else if (_selectedRoomIndex >= _rooms.length ||
                          _selectedRoomIndex < 0) {
                        _selectedRoomIndex = 0;
                      }
                    });
                    if (_selectedRoomIndex >= 0 &&
                        _selectedRoomIndex < _rooms.length) {
                      final cur = _currentRoom;
                      if (cur.isHost) {
                        if (!_audioEngine.isSfuServerRunning) {
                          _audioEngine.startHostSfu(port: cur.port);
                        }
                        _audioEngine.configureSfu(
                          '127.0.0.1',
                          cur.port,
                          cur.roomId,
                          _audioEngine.userId,
                        );
                      } else {
                        if (_audioEngine.isSfuServerRunning) {
                          _audioEngine.stopHostSfu();
                        }
                        final remote = cur.effectivePublicIp;
                        _audioEngine.configureSfu(
                          remote,
                          cur.port,
                          cur.roomId,
                          _audioEngine.userId,
                        );
                      }
                    }
                  }
                } else {
                  if (mounted) {
                    setState(() {
                      _rooms.clear();
                      _selectedRoomIndex = -1;
                    });
                    if (_audioEngine.isSfuServerRunning) {
                      _audioEngine.stopHostSfu();
                    }
                  }
                }
              },
              onError: (e) {
                debugPrint('[Firestore jam_rooms error] $e');
              },
            );
      }
    } catch (e) {
      debugPrint('[Rooms listen init error] $e');
    }
  }

  Future<void> _seedDefaultRoom() async {
    try {
      if (Firebase.apps.isNotEmpty) {
        final user = FirebaseAuth.instance.currentUser;
        final ips = await _audioEngine.detectHostIps();
        final upnp = UpnpService();
        await upnp.openPort(port: 9999);
        await FirebaseFirestore.instance
            .collection('jam_rooms')
            .doc('default-room-1')
            .set({
              'name': '합주실',
              'roomId': 1,
              'iconCode': Icons.music_note.codePoint,
              'description': '합주 공간 (UPnP 자동 개방)',
              'hostUid': user?.uid ?? '',
              'hostName': _currentUserName,
              'hostPublicIp': upnp.publicIp,
              'isUpnpActive': upnp.isPortMapped,
              'hostTailscaleIp': ips['tailscale'] ?? '',
              'hostLanIp': upnp.localLanIp.isNotEmpty
                  ? upnp.localLanIp
                  : (ips['lan'] ?? ''),
              'port': 9999,
              'createdAt': FieldValue.serverTimestamp(),
            });
      }
    } catch (e) {
      debugPrint('[Seed default room note] $e');
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
    _roomsSub?.cancel();
    _audioEngine.stop();
    _audioEngine.stopHostSfu();
    UpnpService().closePort();
    super.dispose();
  }

  void _openAudioSettingsDialog() {
    bool isHostMode = _currentRoom.isHost || _audioEngine.isSfuServerRunning;
    final ipController = TextEditingController(
      text: isHostMode ? '127.0.0.1' : _audioEngine.sfuIp,
    );
    final portController = TextEditingController(
      text: _audioEngine.sfuPort.toString(),
    );
    final roomController = TextEditingController(
      text: _audioEngine.roomId.toString(),
    );
    final userController = TextEditingController(
      text: _audioEngine.userId.toString(),
    );
    int tempBuffer = _audioEngine.bufferSize;
    Map<String, String> localIps = {
      'tailscale': '',
      'lan': '',
      'loopback': '127.0.0.1',
    };

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
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              title: Row(
                children: const [
                  Icon(Icons.tune, color: Color(0xFF5865F2)),
                  SizedBox(width: 8),
                  Text(
                    '오인페 및 SFU 서버 설정',
                    style: TextStyle(color: Colors.white, fontSize: 18),
                  ),
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
                        style: TextStyle(
                          color: Color(0xFFB5BAC1),
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: ChoiceChip(
                              avatar: const Icon(
                                Icons.star,
                                size: 14,
                                color: Color(0xFFFEE75C),
                              ),
                              label: const Text('내가 방장 (로컬 SFU)'),
                              selected: isHostMode,
                              selectedColor: const Color(0xFF5865F2),
                              labelStyle: TextStyle(
                                color: isHostMode
                                    ? Colors.white
                                    : const Color(0xFFB5BAC1),
                                fontSize: 12,
                                fontWeight: isHostMode
                                    ? FontWeight.bold
                                    : FontWeight.normal,
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
                              avatar: const Icon(
                                Icons.headphones,
                                size: 14,
                                color: Color(0xFFDBDEE1),
                              ),
                              label: const Text('게스트 (원격 SFU)'),
                              selected: !isHostMode,
                              selectedColor: const Color(0xFF5865F2),
                              labelStyle: TextStyle(
                                color: !isHostMode
                                    ? Colors.white
                                    : const Color(0xFFB5BAC1),
                                fontSize: 12,
                                fontWeight: !isHostMode
                                    ? FontWeight.bold
                                    : FontWeight.normal,
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
                            border: Border.all(
                              color: const Color(
                                0xFFFEE75C,
                              ).withValues(alpha: 0.4),
                            ),
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
                                      color: _audioEngine.isSfuServerRunning
                                          ? const Color(0xFF23A55A)
                                          : const Color(0xFFDA373C),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    _audioEngine.isSfuServerRunning
                                        ? '내장 SFU 중계 서버 실행 중 (피어: ${_audioEngine.sfuServerPeerCount}명)'
                                        : '내장 SFU 서버 대기/정지 상태',
                                    style: TextStyle(
                                      color: _audioEngine.isSfuServerRunning
                                          ? const Color(0xFF23A55A)
                                          : const Color(0xFFDA373C),
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const Spacer(),
                                  TextButton(
                                    onPressed: () {
                                      final port =
                                          int.tryParse(
                                            portController.text.trim(),
                                          ) ??
                                          9999;
                                      if (_audioEngine.isSfuServerRunning) {
                                        _audioEngine.stopHostSfu();
                                      } else {
                                        _audioEngine.startHostSfu(port: port);
                                      }
                                      setDialogState(() {});
                                    },
                                    child: Text(
                                      _audioEngine.isSfuServerRunning
                                          ? '서버 중지'
                                          : '서버 시작',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: Color(0xFF5865F2),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              if (UpnpService().publicIp.isNotEmpty)
                                Text(
                                  '• 공인 IP: ${UpnpService().publicIp}:${portController.text.trim()} ${UpnpService().isPortMapped ? "(UPnP 개방됨)" : ""}',
                                  style: const TextStyle(
                                    color: Color(0xFF57F287),
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              if (localIps['lan']?.isNotEmpty ?? false)
                                Text(
                                  '• 로컬 LAN IP: ${localIps['lan']}:${portController.text.trim()}',
                                  style: const TextStyle(
                                    color: Color(0xFF949BA4),
                                    fontSize: 11,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: portController,
                          keyboardType: TextInputType.number,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                          ),
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
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                ),
                                decoration: const InputDecoration(
                                  labelText: '접속할 방장 공인 IP (또는 로컬 IP)',
                                  hintText: '예: 112.76.x.x 또는 192.168.0.x',
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
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                ),
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
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                              ),
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
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                              ),
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
                        style: TextStyle(
                          color: Color(0xFFB5BAC1),
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [128, 256, 512, 1024].map((size) {
                          final selected = tempBuffer == size;
                          return ChoiceChip(
                            label: Text(
                              '$size samples (${(size / 48.0).toStringAsFixed(1)}ms)',
                            ),
                            selected: selected,
                            onSelected: (val) {
                              if (val) setDialogState(() => tempBuffer = size);
                            },
                            selectedColor: const Color(0xFF5865F2),
                            labelStyle: TextStyle(
                              color: selected
                                  ? Colors.white
                                  : const Color(0xFFB5BAC1),
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
                              _audioEngine.isNativeLoaded
                                  ? Icons.check_circle
                                  : Icons.info_outline,
                              color: _audioEngine.isNativeLoaded
                                  ? const Color(0xFF23A55A)
                                  : Colors.amber,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _audioEngine.isNativeLoaded
                                    ? 'C++ 네이티브 오디오 코어 연결됨 (ASIO / CoreAudio 직결)'
                                    : '시뮬레이션 모드 (C++ 공유 라이브러리 빌드 대기)',
                                style: TextStyle(
                                  color: _audioEngine.isNativeLoaded
                                      ? const Color(0xFF23A55A)
                                      : Colors.amber,
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
                  child: const Text(
                    '닫기',
                    style: TextStyle(color: Color(0xFF949BA4)),
                  ),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF5865F2),
                  ),
                  onPressed: () {
                    final ip = ipController.text.trim();
                    final port =
                        int.tryParse(portController.text.trim()) ?? 9999;
                    final room = int.tryParse(roomController.text.trim()) ?? 1;
                    final user =
                        int.tryParse(userController.text.trim()) ?? 101;

                    if (isHostMode) {
                      _audioEngine.startHostSfu(port: port);
                      _audioEngine.configureSfu('127.0.0.1', port, room, user);
                      if (_selectedRoomIndex >= 0 && _selectedRoomIndex < _rooms.length) {
                        final cur = _rooms[_selectedRoomIndex];
                        _rooms[_selectedRoomIndex] = JamRoom(
                          id: cur.id,
                          name: cur.name,
                          roomId: room,
                          icon: cur.icon,
                          description: cur.description,
                          hostUid: cur.hostUid,
                          hostName: cur.hostName,
                          hostPublicIp: cur.hostPublicIp,
                          hostTailscaleIp: cur.hostTailscaleIp,
                          hostLanIp: cur.hostLanIp,
                          port: port,
                          isHost: true,
                          isUpnpActive: cur.isUpnpActive,
                          remoteIp: '127.0.0.1',
                          ztNetworkId: cur.ztNetworkId,
                        );
                      }
                    } else {
                      _audioEngine.stopHostSfu();
                      _audioEngine.configureSfu(ip, port, room, user);
                      if (_selectedRoomIndex >= 0 && _selectedRoomIndex < _rooms.length) {
                        final cur = _rooms[_selectedRoomIndex];
                        _rooms[_selectedRoomIndex] = JamRoom(
                          id: cur.id,
                          name: cur.name,
                          roomId: room,
                          icon: cur.icon,
                          description: cur.description,
                          hostUid: cur.hostUid,
                          hostName: cur.hostName,
                          hostPublicIp: cur.hostPublicIp,
                          hostTailscaleIp: cur.hostTailscaleIp,
                          hostLanIp: cur.hostLanIp,
                          port: port,
                          isHost: false,
                          isUpnpActive: cur.isUpnpActive,
                          remoteIp: ip,
                          ztNetworkId: cur.ztNetworkId,
                        );
                      }
                    }
                    _audioEngine.setBufferSize(tempBuffer);
                    setState(() {});

                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          isHostMode
                              ? '방장 모드(내장 SFU 서버)가 활성화되었습니다. (루프백 0ms)'
                              : '게스트 모드로 SFU 서버 ($ip:$port)에 연결되었습니다.',
                        ),
                        backgroundColor: const Color(0xFF23A55A),
                        duration: const Duration(seconds: 3),
                      ),
                    );
                  },
                  child: const Text(
                    '설정 저장',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _joinRoom(JamRoom room, {bool preferLan = false}) {
    final index = _rooms.indexWhere((r) => r.id == room.id);
    final targetIndex = index != -1 ? index : 0;

    setState(() {
      _selectedRoomIndex = targetIndex;
      _selectedChannel = 0;
    });

    if (room.isHost) {
      _audioEngine.startHostSfu(port: room.port);
      UpnpService().openPort(port: room.port).then((_) {
        if (mounted) setState(() {});
      });
      _audioEngine.configureSfu(
        '127.0.0.1',
        room.port,
        room.roomId,
        _audioEngine.userId,
      );
    } else {
      _audioEngine.stopHostSfu();
      String targetIp = '';
      final myLan = UpnpService().localLanIp;
      bool isSameSubnet = false;
      if (myLan.isNotEmpty && room.hostLanIp.isNotEmpty) {
        final myParts = myLan.split('.');
        final hostParts = room.hostLanIp.split('.');
        if (myParts.length == 4 && hostParts.length == 4) {
          isSameSubnet = (myParts[0] == hostParts[0] &&
              myParts[1] == hostParts[1] &&
              myParts[2] == hostParts[2]);
        }
      }

      if ((preferLan || isSameSubnet) && room.hostLanIp.isNotEmpty) {
        targetIp = room.hostLanIp;
      } else if (room.hostPublicIp.isNotEmpty) {
        targetIp = room.hostPublicIp;
      } else if (room.hostLanIp.isNotEmpty) {
        targetIp = room.hostLanIp;
      } else if (room.hostTailscaleIp.isNotEmpty) {
        targetIp = room.hostTailscaleIp;
      } else {
        targetIp = room.remoteIp.isNotEmpty
            ? room.remoteIp
            : _audioEngine.sfuIp;
      }

      _audioEngine.configureSfu(
        targetIp,
        room.port,
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
            Expanded(
              child: Text(
                room.isHost
                    ? '\'${room.name}\' 방장으로 입장했습니다! (내 컴퓨터 로컬 SFU 가동 중)'
                    : '\'${room.name}\' (${room.hostName} 님의 SFU: ${_audioEngine.sfuIp}:${room.port})로 자동 연결되었습니다!',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        backgroundColor: const Color(0xFF23A55A),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _selectRoom(int index) {
    if (index < 0 || index >= _rooms.length) return;
    _joinRoom(_rooms[index]);
  }

  void _openCreateRoomDialog() {
    final nextRoomId =
        _rooms.fold<int>(0, (max, r) => r.roomId > max ? r.roomId : max) + 1;
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
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              title: Row(
                children: const [
                  Icon(Icons.add_circle, color: Color(0xFF5865F2)),
                  SizedBox(width: 8),
                  Text(
                    '새 합주실 개설',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
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
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E1F22),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isHost
                                ? const Color(0xFFFEE75C).withValues(alpha: 0.6)
                                : const Color(0xFF383A40),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: const [
                                      Text(
                                        '내가 이 방의 SFU 호스트(방장) 되기',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 13,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      Text(
                                        '내 컴퓨터에서 SFU 서버를 자동 실행하고 UPnP로 포트를 자동 개방합니다.',
                                        style: TextStyle(
                                          color: Color(0xFF949BA4),
                                          fontSize: 11,
                                        ),
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
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                ),
                                decoration: const InputDecoration(
                                  labelText:
                                      '접속할 SFU 서버 IP (방장의 공인 IP 또는 로컬 IP)',
                                  hintText: '112.76.x.x 또는 192.168.0.x',
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
                        style: TextStyle(
                          color: Color(0xFFB5BAC1),
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: nameController,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
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
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'SFU 방 번호 (Room ID)',
                          hintText: '1, 2, 3...',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        isHost
                            ? '* 내 맥북의 내장 SFU 서버에 고유 채널 번호로 개설됩니다.'
                            : '* 홈 NAS/원격 SFU 서버의 방 번호입니다.',
                        style: const TextStyle(
                          color: Color(0xFF949BA4),
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: descController,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                        ),
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
                        style: TextStyle(
                          color: Color(0xFFB5BAC1),
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: availableIcons.map((iconData) {
                          final isSelected = selectedIcon == iconData;
                          return InkWell(
                            onTap: () =>
                                setDialogState(() => selectedIcon = iconData),
                            borderRadius: BorderRadius.circular(10),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? const Color(0xFF5865F2)
                                    : const Color(0xFF1E1F22),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: isSelected
                                      ? Colors.white
                                      : const Color(0xFF383A40),
                                  width: isSelected ? 2 : 1,
                                ),
                              ),
                              child: Icon(
                                iconData,
                                color: isSelected
                                    ? Colors.white
                                    : const Color(0xFF949BA4),
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
                  child: const Text(
                    '취소',
                    style: TextStyle(color: Color(0xFF949BA4)),
                  ),
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF5865F2),
                  ),
                  onPressed: () async {
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
                    final roomId =
                        int.tryParse(idController.text.trim()) ?? nextRoomId;

                    final ips = await _audioEngine.detectHostIps();
                    final user = FirebaseAuth.instance.currentUser;
                    final hostUid = isHost ? (user?.uid ?? 'local_user') : '';
                    final hostName = _currentUserName;
                    final upnp = UpnpService();
                    if (isHost) {
                      await upnp.openPort(port: _audioEngine.sfuPort);
                    }
                    final publicIp = upnp.publicIp;
                    final lan = upnp.localLanIp.isNotEmpty
                        ? upnp.localLanIp
                        : (ips['lan'] ?? '');
                    final tailscale = ips['tailscale'] ?? '';

                    String newDocId = DateTime.now().millisecondsSinceEpoch
                        .toString();
                    if (Firebase.apps.isNotEmpty) {
                      try {
                        final docRef = await FirebaseFirestore.instance
                            .collection('jam_rooms')
                            .add({
                              'name': name,
                              'roomId': roomId,
                              'iconCode': selectedIcon.codePoint,
                              'description': descController.text.trim(),
                              'hostUid': hostUid,
                              'hostName': hostName,
                              'hostPublicIp': publicIp,
                              'isUpnpActive': upnp.isPortMapped,
                              'hostTailscaleIp': tailscale,
                              'hostLanIp': lan,
                              'port': _audioEngine.sfuPort,
                              'createdAt': FieldValue.serverTimestamp(),
                            });
                        newDocId = docRef.id;
                      } catch (e) {
                        debugPrint('[Firestore add room error] $e');
                      }
                    }

                    final newRoom = JamRoom(
                      id: newDocId,
                      name: name,
                      roomId: roomId,
                      icon: selectedIcon,
                      description: descController.text.trim(),
                      hostUid: hostUid,
                      hostName: hostName,
                      hostPublicIp: publicIp,
                      isUpnpActive: upnp.isPortMapped,
                      hostTailscaleIp: tailscale,
                      hostLanIp: lan,
                      port: _audioEngine.sfuPort,
                      isHost: isHost,
                      remoteIp: isHost
                          ? '127.0.0.1'
                          : remoteIpController.text.trim(),
                    );

                    setState(() {
                      if (!_rooms.any((r) => r.id == newRoom.id)) {
                        _rooms.add(newRoom);
                      }
                    });

                    Navigator.pop(context);
                    _joinRoom(newRoom);
                  },
                  icon: const Icon(Icons.check, color: Colors.white, size: 18),
                  label: const Text(
                    '합주실 개설',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _deleteCurrentRoom() {
    if (_rooms.isEmpty) return;
    _deleteRoom(_currentRoom);
  }

  void _deleteRoom(JamRoom room) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF2B2D31),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          title: const Text(
            '합주실 삭제',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: Text(
            '\'${room.name}\' 합주실을 삭제하시겠습니까?',
            style: const TextStyle(color: Color(0xFFDBDEE1)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                '취소',
                style: TextStyle(color: Color(0xFF949BA4)),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFF23F43),
              ),
              onPressed: () async {
                setState(() {
                  _rooms.removeWhere((r) => r.id == room.id);
                  if (_rooms.isEmpty) {
                    _selectedRoomIndex = -1;
                  } else if (_selectedRoomIndex >= _rooms.length) {
                    _selectedRoomIndex = 0;
                  }
                });
                if (Firebase.apps.isNotEmpty) {
                  try {
                    await FirebaseFirestore.instance
                        .collection('jam_rooms')
                        .doc(room.id)
                        .delete();
                  } catch (e) {
                    debugPrint('[Delete room error] $e');
                  }
                }
                if (_selectedRoomIndex >= 0 && _rooms.isNotEmpty) {
                  _audioEngine.configureSfu(
                    _audioEngine.sfuIp,
                    _audioEngine.sfuPort,
                    _currentRoom.roomId,
                    _audioEngine.userId,
                  );
                } else {
                  _audioEngine.stopHostSfu();
                }
                if (context.mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).hideCurrentSnackBar();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('\'${room.name}\' 합주실이 삭제되었습니다.'),
                      backgroundColor: const Color(0xFF4E5058),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                }
              },
              child: const Text('삭제', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  String get _currentUserName {
    final deepLink = DeepLinkService().currentSession;
    if (deepLink != null && deepLink.userName.isNotEmpty) {
      return deepLink.userName;
    }
    final guest = UserService().nickname;
    if (guest.isNotEmpty && guest != '게스트') {
      return guest;
    }
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
    return guest.isNotEmpty ? guest : '합주자';
  }

  void _openEditNicknameDialog() {
    final controller = TextEditingController(text: _currentUserName);
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF2B2D31),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          title: Row(
            children: const [
              Icon(Icons.badge, color: Color(0xFF5865F2)),
              SizedBox(width: 8),
              Text(
                '닉네임(활동명) 변경',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            decoration: const InputDecoration(
              labelText: '새 닉네임',
              hintText: '합주실과 채팅에서 표시될 이름',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                '취소',
                style: TextStyle(color: Color(0xFF949BA4)),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF5865F2),
              ),
              onPressed: () async {
                final newName = controller.text.trim();
                if (newName.isNotEmpty) {
                  await UserService().setProfile(nickname: newName);
                  if (mounted) {
                    setState(() {});
                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('닉네임이 \'$newName\'(으)로 변경되었습니다.'),
                        backgroundColor: const Color(0xFF23A55A),
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  }
                }
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('변경 저장', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  Future<void> _confirmLogout() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF2B2D31),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          title: Row(
            children: const [
              Icon(Icons.logout, color: Color(0xFFF23F43)),
              SizedBox(width: 8),
              Text(
                '로그아웃',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
            ],
          ),
          content: const Text(
            '정말 합주실에서 로그아웃하시겠습니까?\n저장된 로그인 세션이 해제됩니다.',
            style: TextStyle(color: Color(0xFFDBDEE1), fontSize: 14),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text(
                '취소',
                style: TextStyle(color: Color(0xFF949BA4)),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFF23F43),
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const Text(
                '로그아웃',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        );
      },
    );

    if (confirmed == true) {
      if (_audioEngine.isStreaming) {
        _audioEngine.stop();
      }
      await UserService().clearProfile();
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
                    // 합주 세션 로비 (Home) 아이콘
                    _buildServerIcon(
                      icon: Icons.hub,
                      isActive: _selectedRoomIndex == -1,
                      tooltip: '합주 세션 로비 (전체 목록)',
                      onTap: () {
                        setState(() {
                          _selectedRoomIndex = -1;
                        });
                      },
                    ),
                    const SizedBox(height: 8),
                    const Divider(
                      color: Color(0xFF35363C),
                      indent: 16,
                      endIndent: 16,
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
                          children: [
                            for (int i = 0; i < _rooms.length; i++) ...[
                              _buildServerIcon(
                                icon: _rooms[i].icon,
                                isActive: _selectedRoomIndex == i,
                                tooltip:
                                    '${_rooms[i].name} (방 #${_rooms[i].roomId}, 꾹 눌러 삭제)',
                                onTap: () => _selectRoom(i),
                                onLongPress: () => _deleteRoom(_rooms[i]),
                              ),
                              const SizedBox(height: 8),
                            ],
                            const Divider(
                              color: Color(0xFF35363C),
                              indent: 16,
                              endIndent: 16,
                            ),
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
                      icon: const Icon(
                        Icons.settings,
                        color: Color(0xFF949BA4),
                      ),
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
                    if (_selectedRoomIndex == -1 || _rooms.isEmpty) ...[
                      // 세션 로비 헤더
                      Container(
                        height: 48,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        alignment: Alignment.centerLeft,
                        decoration: const BoxDecoration(
                          border: Border(
                            bottom: BorderSide(color: Color(0xFF1F2023)),
                          ),
                        ),
                        child: Row(
                          children: const [
                            Icon(Icons.hub, color: Color(0xFF5865F2), size: 18),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '합주 세션 로비',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                  fontSize: 14,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),

                      // 세션 로비 메뉴
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.symmetric(
                            vertical: 8,
                            horizontal: 8,
                          ),
                          children: [
                            const Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 6,
                              ),
                              child: Text(
                                '세션 메뉴',
                                style: TextStyle(
                                  color: Color(0xFF949BA4),
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                            _buildHubNavTile(
                              icon: Icons.explore,
                              title: '전체 합주 세션',
                              isActive: true,
                              onTap: () {},
                            ),
                            _buildHubNavTile(
                              icon: Icons.add_circle_outline,
                              title: '새 합주실 개설',
                              isActive: false,
                              onTap: _openCreateRoomDialog,
                            ),
                            _buildHubNavTile(
                              icon: Icons.tune,
                              title: '오인페 / SFU 설정',
                              isActive: false,
                              onTap: _openAudioSettingsDialog,
                            ),
                            const SizedBox(height: 16),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 6,
                              ),
                              child: Row(
                                children: [
                                  const Text(
                                    '개설된 세션',
                                    style: TextStyle(
                                      color: Color(0xFF949BA4),
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                  const Spacer(),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 1,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF1E1F22),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      '${_rooms.length}',
                                      style: const TextStyle(
                                        color: Color(0xFF5865F2),
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            for (int i = 0; i < _rooms.length; i++)
                              _buildHubRoomListTile(_rooms[i], i),
                          ],
                        ),
                      ),
                    ] else ...[
                      // 서버 헤더
                      Container(
                        height: 48,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        alignment: Alignment.centerLeft,
                        decoration: const BoxDecoration(
                          border: Border(
                            bottom: BorderSide(color: Color(0xFF1F2023)),
                          ),
                        ),
                        child: PopupMenuButton<String>(
                          color: const Color(0xFF2B2D31),
                          offset: const Offset(0, 48),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
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
                                  Icon(
                                    Icons.add_circle_outline,
                                    color: Color(0xFF5865F2),
                                    size: 18,
                                  ),
                                  SizedBox(width: 8),
                                  Text(
                                    '새 합주실 개설',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            PopupMenuItem(
                              value: 'settings',
                              child: Row(
                                children: const [
                                  Icon(
                                    Icons.tune,
                                    color: Color(0xFF949BA4),
                                    size: 18,
                                  ),
                                  SizedBox(width: 8),
                                  Text(
                                    '오인페 및 SFU 설정',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (_rooms.length > 1)
                              PopupMenuItem(
                                value: 'delete',
                                child: Row(
                                  children: const [
                                    Icon(
                                      Icons.delete_outline,
                                      color: Color(0xFFF23F43),
                                      size: 18,
                                    ),
                                    SizedBox(width: 8),
                                    Text(
                                      '현재 합주실 닫기',
                                      style: TextStyle(
                                        color: Color(0xFFF23F43),
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            const PopupMenuDivider(height: 1),
                            PopupMenuItem(
                              value: 'logout',
                              child: Row(
                                children: const [
                                  Icon(
                                    Icons.logout,
                                    color: Color(0xFFF23F43),
                                    size: 18,
                                  ),
                                  SizedBox(width: 8),
                                  Text(
                                    '로그아웃',
                                    style: TextStyle(
                                      color: Color(0xFFF23F43),
                                      fontSize: 13,
                                    ),
                                  ),
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
                              const Icon(
                                Icons.keyboard_arrow_down,
                                color: Color(0xFF949BA4),
                                size: 18,
                              ),
                            ],
                          ),
                        ),
                      ),

                      // 채널 카테고리 & 목록
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.symmetric(
                            vertical: 8,
                            horizontal: 8,
                          ),
                          children: [
                            // 로비로 돌아가기 버튼
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 4,
                              ),
                              child: InkWell(
                                onTap: () {
                                  setState(() {
                                    _selectedRoomIndex = -1;
                                  });
                                },
                                borderRadius: BorderRadius.circular(6),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF1E1F22),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: const Color(0xFF383A40),
                                    ),
                                  ),
                                  child: Row(
                                    children: const [
                                      Icon(
                                        Icons.arrow_back,
                                        color: Color(0xFF5865F2),
                                        size: 16,
                                      ),
                                      SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          '전체 세션 목록 (로비)',
                                          style: TextStyle(
                                            color: Color(0xFFDBDEE1),
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            const Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 6,
                              ),
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
                              padding: EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 6,
                              ),
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
                    ],

                    // 하단 내 프로필 & 오인페 상태 영역
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                      color: const Color(0xFF232428),
                      child: Row(
                        children: [
                          Expanded(
                            child: Tooltip(
                              message: '클릭하여 닉네임(활동명) 변경',
                              child: InkWell(
                                onTap: _openEditNicknameDialog,
                                borderRadius: BorderRadius.circular(6),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 2.0,
                                    horizontal: 2.0,
                                  ),
                                  child: Row(
                                    children: [
                                      Stack(
                                        alignment: Alignment.bottomRight,
                                        children: [
                                          CircleAvatar(
                                            radius: 18,
                                            backgroundColor: const Color(
                                              0xFF5865F2,
                                            ),
                                            child: Text(
                                              _currentUserName.isNotEmpty
                                                  ? _currentUserName[0]
                                                        .toUpperCase()
                                                  : '합',
                                              style: const TextStyle(
                                                fontSize: 12,
                                                color: Colors.white,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                          Container(
                                            width: 10,
                                            height: 10,
                                            decoration: BoxDecoration(
                                              color: _audioEngine.isStreaming
                                                  ? const Color(0xFF23A55A)
                                                  : const Color(0xFF80848E),
                                              shape: BoxShape.circle,
                                              border: Border.all(
                                                color: const Color(0xFF232428),
                                                width: 1.5,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Flexible(
                                                  child: Text(
                                                    '$_currentUserName (나)',
                                                    style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      fontSize: 13,
                                                      color: Colors.white,
                                                    ),
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ),
                                                const SizedBox(width: 4),
                                                const Icon(
                                                  Icons.edit_outlined,
                                                  size: 13,
                                                  color: Color(0xFF949BA4),
                                                ),
                                              ],
                                            ),
                                            Text(
                                              _audioEngine.isStreaming
                                                  ? 'UDP 스트리밍 중'
                                                  : '오인페 대기중',
                                              style: TextStyle(
                                                color: _audioEngine.isStreaming
                                                    ? const Color(0xFF23A55A)
                                                    : const Color(0xFF949BA4),
                                                fontSize: 10,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          IconButton(
                            icon: Icon(
                              _audioEngine.isStreaming
                                  ? Icons.mic
                                  : Icons.mic_off,
                              color: _audioEngine.isStreaming
                                  ? const Color(0xFF23A55A)
                                  : const Color(0xFFF23F43),
                              size: 20,
                            ),
                            onPressed: _toggleJamming,
                            tooltip: _audioEngine.isStreaming
                                ? '합주 송출 중지'
                                : '합주 송출 시작',
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.logout,
                              color: Color(0xFF949BA4),
                              size: 18,
                            ),
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
    if (_selectedRoomIndex == -1 || _rooms.isEmpty) {
      return _buildLobbySessionHub();
    }

    switch (_selectedChannel) {
      case 0:
        return JamRoomScreen(
          roomName: _currentRoom.name,
          roomId: _currentRoom.roomId,
          roomDocId: _currentRoom.id,
          isHost: _currentRoom.isHost,
          hostName: _currentRoom.hostName,
          hostPublicIp: _currentRoom.hostPublicIp,
          hostTailscaleIp: _currentRoom.hostTailscaleIp,
          hostLanIp: _currentRoom.hostLanIp,
          hostZeroTierIp: _currentRoom.hostZeroTierIp,
          remoteIp: _currentRoom.remoteIp,
          port: _currentRoom.port,
          ztNetworkId: _currentRoom.ztNetworkId,
          onToggleJam: _toggleJamming,
          isJamming: _audioEngine.isStreaming,
          onOpenSettings: _openAudioSettingsDialog,
        );
      case 1:
        return ChatView(roomId: _currentRoom.id, roomName: _currentRoom.name);
      case 2:
        return LobbyScreen(
          roomId: _currentRoom.id,
          roomName: _currentRoom.name,
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildLobbySessionHub() {
    return Container(
      color: const Color(0xFF313338),
      child: Column(
        children: [
          // 상단 바: 세션 로비 타이틀 및 새 세션 개설 버튼
          Container(
            height: 60,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            decoration: const BoxDecoration(
              color: Color(0xFF2B2D31),
              border: Border(
                bottom: BorderSide(color: Color(0xFF1F2023), width: 1),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.hub, color: Color(0xFF5865F2), size: 24),
                const SizedBox(width: 12),
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text(
                      'GAM 실시간 합주 세션 로비',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      '열려있는 방에 원클릭으로 바로 입장하거나, 내가 방장이 되어 합주실을 열어보세요.',
                      style: TextStyle(color: Color(0xFF949BA4), fontSize: 11),
                    ),
                  ],
                ),
                const Spacer(),
                ElevatedButton.icon(
                  icon: const Icon(Icons.add_circle_outline, size: 18),
                  label: const Text(
                    '새 합주실 개설 (내가 방장)',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF5865F2),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: _openCreateRoomDialog,
                ),
              ],
            ),
          ),

          // 메인 스크롤 영역
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildMyHostStatusBar(),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      const Icon(
                        Icons.meeting_room,
                        color: Color(0xFFDBDEE1),
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '진행 중인 합주실 세션 (${_rooms.length})',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '방장의 IP로 원클릭 자동 설정되어 바로 접속됩니다',
                        style: TextStyle(
                          color: const Color(0xFF5865F2).withValues(alpha: 0.9),
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_rooms.isEmpty)
                    _buildEmptyRoomsState()
                  else
                    Wrap(
                      spacing: 16,
                      runSpacing: 16,
                      children: [
                        for (int i = 0; i < _rooms.length; i++)
                          _buildRoomHubCard(_rooms[i], i),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMyHostStatusBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF2B2D31),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF383A40)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF5865F2).withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.wifi_tethering,
              color: Color(0xFF5865F2),
              size: 20,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '내 활동명: $_currentUserName',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(width: 8),
                    InkWell(
                      onTap: _openEditNicknameDialog,
                      child: const Text(
                        '[닉네임 변경]',
                        style: TextStyle(
                          color: Color(0xFF5865F2),
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  UpnpService().publicIp.isNotEmpty
                      ? '내 공인 IP: ${UpnpService().publicIp} (${UpnpService().isPortMapped ? "공유기 UPnP 포트 9999 자동 개방 완료" : "포트 개방 대기중"})'
                      : '새 합주실을 개설하면 공유기 UPnP로 포트 9999가 자동 개방되어 가상회선 없이 바로 합주할 수 있습니다.',
                  style: TextStyle(
                    color: UpnpService().isPortMapped
                        ? const Color(0xFF57F287)
                        : const Color(0xFF949BA4),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.tune, size: 14, color: Color(0xFFDBDEE1)),
            label: const Text(
              '오인페 / SFU 설정',
              style: TextStyle(color: Color(0xFFDBDEE1), fontSize: 12),
            ),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Color(0xFF4E5058)),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            onPressed: _openAudioSettingsDialog,
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyRoomsState() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(40),
      decoration: BoxDecoration(
        color: const Color(0xFF2B2D31),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF383A40)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.music_off, color: Color(0xFF949BA4), size: 48),
          const SizedBox(height: 16),
          const Text(
            '현재 개설된 합주실이 없습니다',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '내가 첫 번째 방장이 되어 합주실을 개설해보세요!',
            style: TextStyle(color: Color(0xFF949BA4), fontSize: 13),
          ),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            icon: const Icon(Icons.add, size: 18),
            label: const Text('새 합주실 개설하기 (내가 방장)'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF5865F2),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: _openCreateRoomDialog,
          ),
        ],
      ),
    );
  }

  Widget _buildRoomHubCard(JamRoom room, int index) {
    final isSelected = _selectedRoomIndex == index;
    final displayIp = room.effectivePublicIp;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _joinRoom(room),
        onLongPress: () => _deleteRoom(room),
        child: Container(
          width: 380,
          decoration: BoxDecoration(
            color: const Color(0xFF2B2D31),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected
                  ? const Color(0xFF5865F2)
                  : (room.isHost
                        ? const Color(0xFFFEE75C).withValues(alpha: 0.5)
                        : const Color(0xFF383A40)),
              width: isSelected || room.isHost ? 1.5 : 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.2),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: room.isHost
                          ? const Color(0xFFFEE75C).withValues(alpha: 0.15)
                          : const Color(0xFF5865F2).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: room.isHost
                            ? const Color(0xFFFEE75C).withValues(alpha: 0.6)
                            : const Color(0xFF5865F2).withValues(alpha: 0.6),
                      ),
                    ),
                    child: Icon(
                      room.icon,
                      color: room.isHost
                          ? const Color(0xFFFEE75C)
                          : const Color(0xFF5865F2),
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                room.name,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1E1F22),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                '방 #${room.roomId}',
                                style: const TextStyle(
                                  color: Color(0xFF949BA4),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(
                              Icons.person,
                              size: 13,
                              color: room.isHost
                                  ? const Color(0xFFFEE75C)
                                  : const Color(0xFF5865F2),
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                room.isHost
                                    ? '내가 방장 (로컬 SFU)'
                                    : '방장: ${room.hostName.isNotEmpty ? room.hostName : "알 수 없음"}',
                                style: TextStyle(
                                  color: room.isHost
                                      ? const Color(0xFFFEE75C)
                                      : const Color(0xFF5865F2),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              if (room.description.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  room.description,
                  style: const TextStyle(
                    color: Color(0xFF949BA4),
                    fontSize: 12,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],

              const SizedBox(height: 14),

              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1F22),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF35363C)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          room.isUpnpActive ? Icons.lock_open : Icons.language,
                          size: 14,
                          color: room.isUpnpActive
                              ? const Color(0xFF57F287)
                              : const Color(0xFF5865F2),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          room.isUpnpActive ? 'UPnP 공인 IP: ' : '공인 IP: ',
                          style: const TextStyle(
                            color: Color(0xFF949BA4),
                            fontSize: 11,
                          ),
                        ),
                        Expanded(
                          child: Text(
                            '$displayIp:${room.port}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.bold,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.copy,
                            size: 14,
                            color: Color(0xFF949BA4),
                          ),
                          tooltip: 'IP 복사',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          onPressed: () {
                            Clipboard.setData(
                              ClipboardData(text: '$displayIp:${room.port}'),
                            );
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'IP 주소가 복사되었습니다: $displayIp:${room.port}',
                                ),
                                duration: const Duration(seconds: 1),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                    if (room.hostLanIp.isNotEmpty &&
                        room.hostLanIp != displayIp) ...[
                      const SizedBox(height: 4),
                      Text(
                        '• 같은 Wi-Fi 로컬 접속: ${room.hostLanIp}:${room.port}',
                        style: const TextStyle(
                          color: Color(0xFF72767D),
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 14),

              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: Icon(
                        room.isHost ? Icons.login : Icons.arrow_forward,
                        size: 16,
                      ),
                      label: Text(
                        room.isHost ? '방장으로 세션 입장' : '바로 입장',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: room.isHost
                            ? const Color(0xFF5865F2)
                            : const Color(0xFF23A55A),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      onPressed: () => _joinRoom(room),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(
                      Icons.delete_outline,
                      color: Color(0xFFF23F43),
                      size: 18,
                    ),
                    tooltip: '합주실 삭제 (꾹 눌러서도 삭제 가능)',
                    onPressed: () => _deleteRoom(room),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHubNavTile({
    required IconData icon,
    required String title,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: isActive ? const Color(0xFF404249) : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: ListTile(
          leading: Icon(
            icon,
            color: isActive ? Colors.white : const Color(0xFF80848E),
            size: 18,
          ),
          title: Text(
            title,
            style: TextStyle(
              color: isActive ? Colors.white : const Color(0xFF949BA4),
              fontSize: 13,
              fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          dense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 0,
          ),
          onTap: onTap,
        ),
      ),
    );
  }

  Widget _buildHubRoomListTile(JamRoom room, int index) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: ListTile(
          leading: Icon(
            room.icon,
            color: room.isHost
                ? const Color(0xFFFEE75C)
                : const Color(0xFF5865F2),
            size: 18,
          ),
          title: Text(
            room.name,
            style: const TextStyle(color: Color(0xFFDBDEE1), fontSize: 12),
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            room.isHost ? '내가 방장' : '방장: ${room.hostName}',
            style: const TextStyle(color: Color(0xFF72767D), fontSize: 10),
            overflow: TextOverflow.ellipsis,
          ),
          dense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 0,
          ),
          onTap: () => _joinRoom(room),
          onLongPress: () => _deleteRoom(room),
        ),
      ),
    );
  }

  Widget _buildServerIcon({
    required IconData icon,
    required bool isActive,
    required String tooltip,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
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
                onLongPress: onLongPress,
                borderRadius: BorderRadius.circular(isActive ? 16 : 24),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: isActive
                        ? const Color(0xFF5865F2)
                        : (isAddButton
                              ? const Color(0xFF2B2D31)
                              : const Color(0xFF313338)),
                    borderRadius: BorderRadius.circular(isActive ? 16 : 24),
                    border: isAddButton
                        ? Border.all(
                            color: const Color(
                              0xFF23A55A,
                            ).withValues(alpha: 0.5),
                            width: 1.5,
                          )
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
                    fontWeight: isSelected
                        ? FontWeight.bold
                        : FontWeight.normal,
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
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 0,
          ),
          onTap: () => setState(() => _selectedChannel = index),
        ),
      ),
    );
  }
}
