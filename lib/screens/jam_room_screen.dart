import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/audio_engine.dart';
import '../services/upnp_service.dart';
import '../services/zerotier_service.dart';
import '../services/deep_link_service.dart';
import '../services/user_service.dart';

class PeerState {
  final int userId;
  final String name;
  final String instrument;
  final String audioInterface;
  double volume;
  bool isMuted;
  double level;

  PeerState({
    required this.userId,
    required this.name,
    required this.instrument,
    required this.audioInterface,
    this.volume = 0.85,
    this.isMuted = false,
    this.level = 0.0,
  });
}

class JamRoomScreen extends StatefulWidget {
  final VoidCallback onToggleJam;
  final bool isJamming;
  final VoidCallback onOpenSettings;
  final String? roomName;
  final int roomId;
  final String? roomDocId;
  final bool isHost;
  final String hostName;
  final String hostPublicIp;
  final String hostTailscaleIp;
  final String hostLanIp;
  final String hostZeroTierIp;
  final String remoteIp;
  final int port;
  final String? ztNetworkId;

  const JamRoomScreen({
    super.key,
    required this.onToggleJam,
    required this.isJamming,
    required this.onOpenSettings,
    this.roomName,
    this.roomId = 1,
    this.roomDocId,
    this.isHost = true,
    this.hostName = '방장',
    this.hostPublicIp = '',
    this.hostTailscaleIp = '',
    this.hostLanIp = '',
    this.hostZeroTierIp = '',
    this.remoteIp = '',
    this.port = 9999,
    this.ztNetworkId,
  });

  String get effectivePublicIp {
    // 1. 방장의 공인 IP (UPnP 공유기 직결 또는 포트포워딩): 국내 3~15ms 초저지연 직결 우선
    if (hostPublicIp.isNotEmpty && hostPublicIp != '127.0.0.1') return hostPublicIp;
    // 2. 수동 지정된 remoteIp
    if (remoteIp.isNotEmpty && remoteIp != '127.0.0.1') return remoteIp;
    // 3. 로컬 공유기/Wi-Fi LAN IP (동일 네트워크 시 1ms 미만)
    if (hostLanIp.isNotEmpty && hostLanIp != '127.0.0.1') return hostLanIp;
    // 4. 가상 사설망(ZeroTier / Tailscale)은 공인 IP 직결 불가 시의 안전 폴백
    if (hostZeroTierIp.isNotEmpty) return hostZeroTierIp;
    return hostTailscaleIp;
  }

  @override
  State<JamRoomScreen> createState() => _JamRoomScreenState();
}

class _JamRoomScreenState extends State<JamRoomScreen> {
  final AudioEngine _audioEngine = AudioEngine();
  final UpnpService _upnpService = UpnpService();
  late final List<PeerState> _peers;
  StreamSubscription<dynamic>? _membersSub;
  bool _isUpnpLoading = false;
  Map<String, String> _hostIps = {
    'tailscale': '',
    'lan': '',
    'loopback': '127.0.0.1',
  };

  late bool _isHost;
  bool _userOverrodeHost = false;

  String _getMyName() {
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

  @override
  void initState() {
    super.initState();
    final deepLink = DeepLinkService().currentSession;
    if (deepLink != null && !deepLink.isHost) {
      _isHost = false;
    } else {
      _isHost = widget.isHost;
    }

    _peers = [
      PeerState(
        userId: _audioEngine.userId,
        name: '${_getMyName()} (나)',
        instrument: '내 악기 / 오디오 인터페이스',
        audioInterface: 'CoreAudio / ASIO 연결됨',
      ),
    ];
    _syncPresence();
    _loadHostIps();
    if (_isHost) {
      if (!_audioEngine.isSfuServerRunning) {
        _audioEngine.startHostSfu(port: widget.port);
      }
      _triggerUpnp();
    } else {
      if (_audioEngine.isSfuServerRunning) {
        _audioEngine.stopHostSfu();
      }
      final targetIp = widget.effectivePublicIp.isNotEmpty
          ? widget.effectivePublicIp
          : (widget.hostLanIp.isNotEmpty ? widget.hostLanIp : '127.0.0.1');
      _audioEngine.configureSfu(
        targetIp,
        widget.port,
        widget.roomId,
        _audioEngine.userId,
      );
    }

    // ZeroTier 1회용 가상 랜 자동 참여
    final ztNet = widget.ztNetworkId ?? DeepLinkService().currentSession?.ztNetworkId;
    if (ztNet != null && ztNet.isNotEmpty) {
      ZeroTierService().joinNetwork(ztNet).then((success) {
        if (success && mounted) {
          final virtualIp = ZeroTierService().assignedVirtualIp.value;
          if (virtualIp != null && virtualIp.isNotEmpty) {
            if (_isHost && Firebase.apps.isNotEmpty) {
              final docId = widget.roomDocId ?? 'discord-room-${widget.roomId}';
              FirebaseFirestore.instance.collection('jam_rooms').doc(docId).set({
                'hostZeroTierIp': virtualIp,
              }, SetOptions(merge: true));
            }
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('🛡️ ZeroTier 1회용 가상 회선 연결 완료 (가상 IP: $virtualIp)'),
                backgroundColor: const Color(0xFF23A55A),
                duration: const Duration(seconds: 3),
              ),
            );
          }
          setState(() {});
        }
      });
    }
  }

  void _syncPresence() {
    if (Firebase.apps.isEmpty) return;
    try {
      final user = FirebaseAuth.instance.currentUser;
      final uid = user?.uid ?? 'anon_${_audioEngine.userId}';
      final docId = widget.roomDocId ?? widget.roomId.toString();

      FirebaseFirestore.instance
          .collection('jam_rooms')
          .doc(docId)
          .collection('members')
          .doc(uid)
          .set({
        'name': _getMyName(),
        'uid': uid,
        'userId': _audioEngine.userId,
        'isHost': _isHost,
        'instrument': _isHost ? '방장 (호스트)' : '합주 세션 멤버',
        'joinedAt': FieldValue.serverTimestamp(),
      });

      _membersSub = FirebaseFirestore.instance
          .collection('jam_rooms')
          .doc(docId)
          .collection('members')
          .snapshots()
          .listen((snapshot) {
        if (!mounted) return;
        final newPeers = <PeerState>[];
        newPeers.add(PeerState(
          userId: _audioEngine.userId,
          name: '${_getMyName()} (나)',
          instrument: '내 악기 / 오디오 인터페이스',
          audioInterface: 'CoreAudio / ASIO 연결됨',
        ));

        for (final doc in snapshot.docs) {
          if (doc.id == uid) continue;
          final data = doc.data();
          final peerUserId = (data['userId'] as int?) ?? 102;
          final name = (data['name'] as String?) ?? '합주자';
          final instrument = (data['instrument'] as String?) ?? '합주 멤버';
          newPeers.add(PeerState(
            userId: peerUserId,
            name: name,
            instrument: instrument,
            audioInterface: '실시간 스트리밍 연결됨',
          ));
        }

        setState(() {
          _peers.clear();
          _peers.addAll(newPeers);
        });
      }, onError: (e) {
        debugPrint('[JamRoom members sync error] $e');
      });
    } catch (e) {
      debugPrint('[JamRoom presence error] $e');
    }
  }

  @override
  void dispose() {
    _membersSub?.cancel();
    if (Firebase.apps.isNotEmpty) {
      try {
        final user = FirebaseAuth.instance.currentUser;
        final uid = user?.uid ?? 'anon_${_audioEngine.userId}';
        final docId = widget.roomDocId ?? widget.roomId.toString();
        FirebaseFirestore.instance
            .collection('jam_rooms')
            .doc(docId)
            .collection('members')
            .doc(uid)
            .delete()
            .catchError((_) {});
      } catch (_) {}
    }

    final ztNet = widget.ztNetworkId ?? DeepLinkService().currentSession?.ztNetworkId;
    if (ztNet != null && ztNet.isNotEmpty) {
      ZeroTierService().leaveNetwork(ztNet);
    }
    super.dispose();
  }

  Future<void> _triggerUpnp() async {
    if (!_isHost) return;
    setState(() {
      _isUpnpLoading = true;
    });
    await _upnpService.openPort(port: widget.port);
    if (mounted) {
      setState(() {
        _isUpnpLoading = false;
      });
    }
  }

  @override
  void didUpdateWidget(JamRoomScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isHost &&
        (widget.hostZeroTierIp != oldWidget.hostZeroTierIp ||
            widget.remoteIp != oldWidget.remoteIp ||
            widget.hostPublicIp != oldWidget.hostPublicIp) &&
        widget.effectivePublicIp.isNotEmpty) {
      _audioEngine.configureSfu(
        widget.effectivePublicIp,
        widget.port,
        widget.roomId,
        _audioEngine.userId,
      );
    }
    if (!_userOverrodeHost && widget.isHost != oldWidget.isHost) {
      _isHost = widget.isHost;
      if (_isHost) {
        if (!_audioEngine.isSfuServerRunning) {
          _audioEngine.startHostSfu(port: widget.port);
        }
        _triggerUpnp();
      } else {
        if (_audioEngine.isSfuServerRunning) {
          _audioEngine.stopHostSfu();
        }
        final targetIp = widget.effectivePublicIp.isNotEmpty
            ? widget.effectivePublicIp
            : (widget.hostLanIp.isNotEmpty ? widget.hostLanIp : '127.0.0.1');
        _audioEngine.configureSfu(
          targetIp,
          widget.port,
          widget.roomId,
          _audioEngine.userId,
        );
      }
      setState(() {});
    }
  }

  void _toggleHostMode() {
    setState(() {
      _isHost = !_isHost;
      _userOverrodeHost = true;
    });

    if (_isHost) {
      _audioEngine.startHostSfu(port: widget.port);
      _audioEngine.configureSfu(
        '127.0.0.1',
        widget.port,
        widget.roomId,
        _audioEngine.userId,
      );
      _triggerUpnp();
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('👑 방장(호스트) 모드로 전환되었습니다. 내장 SFU 서버가 가동되었습니다.'),
          backgroundColor: Color(0xFF23A55A),
          duration: Duration(seconds: 3),
        ),
      );
    } else {
      _audioEngine.stopHostSfu();
      final targetIp = widget.effectivePublicIp.isNotEmpty
          ? widget.effectivePublicIp
          : (widget.hostLanIp.isNotEmpty ? widget.hostLanIp : '127.0.0.1');
      _audioEngine.configureSfu(
        targetIp,
        widget.port,
        widget.roomId,
        _audioEngine.userId,
      );
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('🎧 게스트 모드로 전환되었습니다. (타깃: $targetIp:${widget.port})'),
          backgroundColor: const Color(0xFF5865F2),
          duration: const Duration(seconds: 3),
        ),
      );
    }
    _syncPresence();
  }

  Future<void> _loadHostIps() async {
    final ips = await _audioEngine.detectHostIps();
    if (mounted) {
      setState(() {
        _hostIps = ips;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _audioEngine,
      builder: (context, _) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. 상단 세션 헤더 & 제어 바
              _buildTopSessionBar(),
              const SizedBox(height: 14),
              if (_isHost)
                _buildHostControlCard()
              else
                _buildGuestControlCard(),
              const SizedBox(height: 16),

              // 2. 실시간 상태 및 버퍼/레이턴시 모니터 바
              _buildLatencyStatusBanner(),
              const SizedBox(height: 20),

              // 3. 참여자 카드 그리드 (반응형 LayoutBuilder 적용)
              _buildPeersGrid(),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHostControlCard() {
    final publicIp = _upnpService.publicIp.isNotEmpty
        ? _upnpService.publicIp
        : widget.effectivePublicIp;
    final lan = _upnpService.localLanIp.isNotEmpty
        ? _upnpService.localLanIp
        : (_hostIps['lan'] ?? widget.hostLanIp);
    final port = _audioEngine.sfuServerPort;
    final isRunning = _audioEngine.isSfuServerRunning;
    final isUpnpMapped = _upnpService.isPortMapped;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1F22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isRunning
              ? const Color(0xFFFEE75C).withValues(alpha: 0.5)
              : const Color(0xFF4E5058),
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Wrap(
                spacing: 10,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEE75C).withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      '내가 이 방의 SFU 호스트 (방장)',
                      style: TextStyle(
                        color: Color(0xFFFEE75C),
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: isRunning
                          ? const Color(0xFF23A55A).withValues(alpha: 0.2)
                          : const Color(0xFFDA373C).withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isRunning
                                ? const Color(0xFF23A55A)
                                : const Color(0xFFDA373C),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          isRunning
                              ? 'SFU 중계 서버 가동 중 (UDP $port)'
                              : 'SFU 서버 정지됨',
                          style: TextStyle(
                            color: isRunning
                                ? const Color(0xFF23A55A)
                                : const Color(0xFFDA373C),
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: isUpnpMapped
                          ? const Color(0xFF23A55A).withValues(alpha: 0.15)
                          : const Color(0xFFFEE75C).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isUpnpMapped ? Icons.router : Icons.info_outline,
                          size: 13,
                          color: isUpnpMapped
                              ? const Color(0xFF23A55A)
                              : const Color(0xFFFEE75C),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          isUpnpMapped
                              ? '공유기 UPnP 포트 개방 완료'
                              : '공인 IP 직결 (UPnP 포워딩 준비)',
                          style: TextStyle(
                            color: isUpnpMapped
                                ? const Color(0xFF23A55A)
                                : const Color(0xFFFEE75C),
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isRunning
                          ? const Color(0xFFDA373C)
                          : const Color(0xFF23A55A),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    onPressed: () {
                      if (isRunning) {
                        _audioEngine.stopHostSfu();
                      } else {
                        _audioEngine.startHostSfu(port: widget.port);
                      }
                      setState(() {});
                    },
                    icon: Icon(
                      isRunning ? Icons.stop : Icons.play_arrow,
                      size: 15,
                    ),
                    label: Text(
                      isRunning ? '서버 중지' : 'SFU 서버 가동하기',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF949BA4),
                      side: const BorderSide(color: Color(0xFF4E5058)),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                    ),
                    onPressed: _toggleHostMode,
                    icon: const Icon(Icons.headphones, size: 14),
                    label: const Text('게스트 전환', style: TextStyle(fontSize: 11)),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF5865F2),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                    ),
                    onPressed: _isUpnpLoading ? null : _triggerUpnp,
                    icon: _isUpnpLoading
                        ? const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.sync, size: 16),
                    label: const Text(
                      'UPnP 포트 다시 열기',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // 공인 IP Chip (UPnP)
              _buildIpChip(
                label: '공인 IP (친구 전달용 - UPnP 자동 개방)',
                ip: publicIp.isNotEmpty
                    ? '$publicIp:$port'
                    : '공인 IP 확인 중...',
                icon: Icons.language,
                isPrimary: true,
                copyValue: publicIp.isNotEmpty ? publicIp : '',
              ),
              // LAN IP Chip
              _buildIpChip(
                label: '로컬 LAN IP (같은 Wi-Fi 공유기용)',
                ip: lan.isNotEmpty ? '$lan:$port' : '로컬 IP 확인 불가',
                icon: Icons.wifi,
                isPrimary: false,
                copyValue: lan.isNotEmpty ? lan : '',
              ),
              // ZeroTier 1회용 P2P 가상 회선 Chip
              ValueListenableBuilder<String?>(
                valueListenable: ZeroTierService().assignedVirtualIp,
                builder: (context, ztIp, _) {
                  final netId = ZeroTierService().currentNetworkId.value ??
                      widget.ztNetworkId ??
                      DeepLinkService().currentSession?.ztNetworkId;
                  if (netId == null && ztIp == null) {
                    return const SizedBox.shrink();
                  }
                  final bool hasZtIp = ztIp != null && ztIp.isNotEmpty;
                  return _buildIpChip(
                    label: 'ZeroTier 1회용 P2P 가상 IP',
                    ip: hasZtIp
                        ? '$ztIp:$port (활성)'
                        : 'ZeroTier 연결 중... (${netId ?? ''})',
                    icon: Icons.shield_outlined,
                    isPrimary: hasZtIp,
                    copyValue: ztIp ?? '',
                  );
                },
              ),
              // Full invite copy button
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF5865F2),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onPressed: () {
                  final bestIp = publicIp.isNotEmpty
                      ? publicIp
                      : (lan.isNotEmpty ? lan : '127.0.0.1');
                  final inviteText =
                      '[${widget.roomName ?? '합주실'}] 온라인 합주 초대 안내\n'
                      '• 방 번호: #${_audioEngine.roomId}\n'
                      '• SFU 서버 공인 IP: $bestIp\n'
                      '• UDP 포트: $port\n'
                      '※ 공유기 UPnP로 포트가 자동 개방되어 가상회선 없이 원클릭으로 바로 접속할 수 있습니다!';
                  Clipboard.setData(ClipboardData(text: inviteText));
                  ScaffoldMessenger.of(context).hideCurrentSnackBar();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('친구 초대 안내문이 복사되었습니다. (카톡/디스코드에 붙여넣기)'),
                      backgroundColor: Color(0xFF23A55A),
                      duration: Duration(seconds: 3),
                    ),
                  );
                },
                icon: const Icon(Icons.copy, size: 16),
                label: const Text(
                  '전체 초대 정보 복사',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGuestControlCard() {
    final hostPublic = widget.effectivePublicIp;
    final hostLan = widget.hostLanIp;
    final port = widget.port;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1F22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFF5865F2).withValues(alpha: 0.5),
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF5865F2).withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '게스트 접속 모드 (방장: ${widget.hostName})',
                      style: const TextStyle(
                        color: Color(0xFF5865F2),
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF23A55A).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color(0xFF23A55A),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'SFU 타겟: ${_audioEngine.sfuIp}:${_audioEngine.sfuPort}',
                          style: const TextStyle(
                            color: Color(0xFF23A55A),
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF5865F2),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    onPressed: _toggleHostMode,
                    icon: const Icon(Icons.star, size: 14),
                    label: const Text(
                      '내가 방장으로 서버 켜기',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF949BA4),
                      side: const BorderSide(color: Color(0xFF4E5058)),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                    ),
                    onPressed: widget.onOpenSettings,
                    icon: const Icon(Icons.settings, size: 14),
                    label: const Text('연결 IP 설정', style: TextStyle(fontSize: 11)),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _buildIpChip(
                label: '방장의 공인 IP (UPnP 공유기 직결)',
                ip: hostPublic.isNotEmpty
                    ? '$hostPublic:$port'
                    : '방장 공인 IP 미등록 (설정 확인)',
                icon: Icons.language,
                isPrimary: true,
                copyValue: hostPublic,
                onSelect: hostPublic.isNotEmpty
                    ? () {
                        _audioEngine.configureSfu(
                          hostPublic,
                          port,
                          widget.roomId,
                          _audioEngine.userId,
                        );
                        setState(() {});
                        ScaffoldMessenger.of(context).hideCurrentSnackBar();
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              '접속 IP가 방장 공인 IP ($hostPublic:$port)로 변경되었습니다.',
                            ),
                            backgroundColor: const Color(0xFF23A55A),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      }
                    : null,
              ),
              if (hostLan.isNotEmpty)
                _buildIpChip(
                  label: '방장의 로컬 LAN IP (동일 Wi-Fi)',
                  ip: '$hostLan:$port',
                  icon: Icons.wifi,
                  isPrimary: false,
                  copyValue: hostLan,
                  onSelect: () {
                    _audioEngine.configureSfu(
                      hostLan,
                      port,
                      widget.roomId,
                      _audioEngine.userId,
                    );
                    setState(() {});
                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          '접속 IP가 로컬 Wi-Fi IP ($hostLan:$port)로 변경되었습니다.',
                        ),
                        backgroundColor: const Color(0xFF23A55A),
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  },
                ),
              // ZeroTier 1회용 P2P 가상 회선 Chip
              ValueListenableBuilder<String?>(
                valueListenable: ZeroTierService().assignedVirtualIp,
                builder: (context, ztIp, _) {
                  final netId = ZeroTierService().currentNetworkId.value ??
                      widget.ztNetworkId ??
                      DeepLinkService().currentSession?.ztNetworkId;
                  if (netId == null && ztIp == null) {
                    return const SizedBox.shrink();
                  }
                  final hostZtIp = widget.hostZeroTierIp.isNotEmpty
                      ? widget.hostZeroTierIp
                      : DeepLinkService().currentSession?.hostIp;
                  final bool hasZtIp = ztIp != null && ztIp.isNotEmpty;
                  final String displayIp = hasZtIp
                      ? '내 가상 IP: $ztIp' +
                          (hostZtIp != null && hostZtIp.isNotEmpty
                              ? ' (방장: $hostZtIp:$port)'
                              : '')
                      : 'ZeroTier 가상 네트워크 연결 중... (${netId ?? ''})';

                  return _buildIpChip(
                    label: 'ZeroTier 1회용 P2P 가상 회선',
                    ip: displayIp,
                    icon: Icons.shield_outlined,
                    isPrimary: hasZtIp,
                    copyValue: hostZtIp ?? ztIp ?? '',
                    onSelect: (hostZtIp != null && hostZtIp.isNotEmpty)
                        ? () {
                            _audioEngine.configureSfu(
                              hostZtIp,
                              port,
                              widget.roomId,
                              _audioEngine.userId,
                            );
                            setState(() {});
                            ScaffoldMessenger.of(context).hideCurrentSnackBar();
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  '접속 IP가 방장 ZeroTier IP ($hostZtIp:$port)로 변경되었습니다.',
                                ),
                                backgroundColor: const Color(0xFF23A55A),
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          }
                        : null,
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildIpChip({
    required String label,
    required String ip,
    required IconData icon,
    required bool isPrimary,
    required String copyValue,
    VoidCallback? onSelect,
  }) {
    final bool isSelected = _audioEngine.sfuIp == copyValue && copyValue.isNotEmpty;

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onSelect,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF23A55A).withValues(alpha: 0.15)
              : const Color(0xFF2B2D31),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected
                ? const Color(0xFF23A55A)
                : (isPrimary
                    ? const Color(0xFF5865F2).withValues(alpha: 0.6)
                    : const Color(0xFF383A40)),
            width: isSelected ? 1.8 : 1.0,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: isSelected
                  ? const Color(0xFF23A55A)
                  : (isPrimary ? const Color(0xFF5865F2) : const Color(0xFF949BA4)),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: isSelected
                            ? const Color(0xFF23A55A)
                            : const Color(0xFF949BA4),
                        fontSize: 10,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                    if (isSelected) ...[
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: const Color(0xFF23A55A),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          '현재 접속 대상',
                          style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ],
                ),
                Text(
                  ip,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: (isPrimary || isSelected)
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
              ],
            ),
            if (copyValue.isNotEmpty) ...[
              const SizedBox(width: 8),
              InkWell(
                borderRadius: BorderRadius.circular(4),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: copyValue));
                  ScaffoldMessenger.of(context).hideCurrentSnackBar();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('$label ($copyValue) 복사되었습니다.'),
                      backgroundColor: const Color(0xFF23A55A),
                      duration: const Duration(seconds: 1),
                    ),
                  );
                },
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.copy, size: 13, color: Color(0xFFB5BAC1)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTopSessionBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF2B2D31),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF383A40)),
      ),
      child: Wrap(
        spacing: 16,
        runSpacing: 12,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: widget.isJamming
                      ? const Color(0xFF23A55A).withValues(alpha: 0.2)
                      : const Color(0xFF4E5058).withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.album,
                  color: widget.isJamming
                      ? const Color(0xFF23A55A)
                      : const Color(0xFF949BA4),
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        widget.roomName ?? '서울-경기 무압축 UDP 합주실',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: widget.isJamming
                              ? const Color(0xFF23A55A)
                              : const Color(0xFF4E5058),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          widget.isJamming ? 'ON-AIR' : 'STANDBY',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'SFU NAS: ${_audioEngine.sfuIp}:${_audioEngine.sfuPort}  |  방 번호 #${_audioEngine.roomId}',
                    style: const TextStyle(
                      color: Color(0xFF949BA4),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: _isHost
                      ? const Color(0xFFFEE75C)
                      : const Color(0xFF5865F2),
                  side: BorderSide(
                    color: _isHost
                        ? const Color(0xFFFEE75C).withValues(alpha: 0.6)
                        : const Color(0xFF5865F2).withValues(alpha: 0.6),
                  ),
                  backgroundColor: _isHost
                      ? const Color(0xFFFEE75C).withValues(alpha: 0.12)
                      : const Color(0xFF5865F2).withValues(alpha: 0.12),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onPressed: _toggleHostMode,
                icon: Icon(
                  _isHost ? Icons.workspace_premium : Icons.headphones,
                  size: 18,
                ),
                label: Text(
                  _isHost ? '방장(호스트) 모드' : '게스트 모드',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFDBDEE1),
                  side: const BorderSide(color: Color(0xFF4E5058)),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onPressed: widget.onOpenSettings,
                icon: const Icon(Icons.tune, size: 18),
                label: const Text('오인페 / NAS 설정'),
              ),
              const SizedBox(width: 10),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: widget.isJamming
                      ? const Color(0xFFDA373C)
                      : const Color(0xFF23A55A),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  elevation: 0,
                ),
                onPressed: widget.onToggleJam,
                icon: Icon(widget.isJamming ? Icons.stop : Icons.play_arrow),
                label: Text(
                  widget.isJamming ? '합주 송출 중지' : '실시간 합주 시작 (UDP)',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLatencyStatusBanner() {
    final bufferMs = (_audioEngine.bufferSize / 48.0).toStringAsFixed(2);
    final totalLatency = (_audioEngine.currentRtt + double.parse(bufferMs))
        .toStringAsFixed(1);
    final rtt = _audioEngine.currentRtt;
    final Color rttColor = rtt <= 30.0
        ? const Color(0xFF23A55A)
        : (rtt <= 80.0 ? const Color(0xFFFEE75C) : const Color(0xFFED4245));

    final hostPublic = widget.hostPublicIp;
    final hostLan = widget.hostLanIp;
    final isRelaySuspected = rtt > 80.0 && !_isHost && (hostPublic.isNotEmpty || hostLan.isNotEmpty);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1F22),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF35363C)),
      ),
      child: Wrap(
        spacing: 20,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.spaceBetween,
        children: [
          // 버퍼 사이즈 선택 칩
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text(
                '오인페 버퍼:',
                style: TextStyle(
                  color: Color(0xFF949BA4),
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 2),
              _buildBufferChip(128, '128 samples (2.7ms)'),
              _buildBufferChip(256, '256 samples (5.3ms)'),
              _buildBufferChip(512, '512 samples (10.7ms) [표준]'),
              _buildBufferChip(1024, '1024 samples (21.3ms) [안정]'),
            ],
          ),

          // 레이턴시 및 패킷 지표
          Wrap(
            spacing: 12,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.speed, color: rttColor, size: 18),
                  const SizedBox(width: 6),
                  Text(
                    'RTT 네트워크: ${rtt.toStringAsFixed(1)}ms',
                    style: TextStyle(
                      color: rttColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: rttColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '총 지연: 약 $totalLatency ms',
                      style: TextStyle(
                        color: rttColor,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              if (isRelaySuspected)
                InkWell(
                  onTap: () {
                    final target = hostPublic.isNotEmpty ? hostPublic : hostLan;
                    _audioEngine.configureSfu(
                      target,
                      widget.port,
                      widget.roomId,
                      _audioEngine.userId,
                    );
                    setState(() {});
                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('⚡ 직결 IP ($target:${widget.port})로 즉시 전환되었습니다!'),
                        backgroundColor: const Color(0xFF23A55A),
                        duration: const Duration(seconds: 3),
                      ),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFFED4245).withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFFED4245)),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.bolt, color: Color(0xFFED4245), size: 14),
                        SizedBox(width: 4),
                        Text(
                          '해외 중계 감지됨 ➔ 공인 IP 직결로 전환 (10ms 이하)',
                          style: TextStyle(
                            color: Color(0xFFED4245),
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    widget.isJamming
                        ? (_audioEngine.rxPackets > 0 || _isHost
                            ? Icons.wifi_tethering
                            : Icons.sync)
                        : Icons.wifi_off,
                    color: widget.isJamming
                        ? (_audioEngine.rxPackets > 0 || _isHost
                            ? const Color(0xFF57F287)
                            : const Color(0xFFFEE75C))
                        : const Color(0xFF949BA4),
                    size: 16,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    widget.isJamming
                        ? (_isHost
                            ? 'SFU 가동 중 (송신: ${_audioEngine.txPackets} pkts | 활성 피어: ${_audioEngine.remotePeersCount}명)'
                            : (_audioEngine.rxPackets > 0
                                ? '방장 신호 수신 중 (수신: ${_audioEngine.rxPackets} pkts, 송신: ${_audioEngine.txPackets})'
                                : '방장 신호 대기 중 (송신: ${_audioEngine.txPackets} pkts)'))
                        : '합주 대기 상태 (송출 시작 필요)',
                    style: TextStyle(
                      color: widget.isJamming
                          ? (_audioEngine.rxPackets > 0 || _isHost
                              ? const Color(0xFF57F287)
                              : const Color(0xFFFEE75C))
                          : const Color(0xFF949BA4),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBufferChip(int size, String label) {
    final isSelected = _audioEngine.bufferSize == size;
    return InkWell(
      onTap: () {
        _audioEngine.setBufferSize(size);
        setState(() {});
      },
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF5865F2) : const Color(0xFF2B2D31),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isSelected
                ? const Color(0xFF5865F2)
                : const Color(0xFF3F4147),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : const Color(0xFFB5BAC1),
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _buildPeersGrid() {
    return LayoutBuilder(
      builder: (context, constraints) {
        int crossAxisCount = 3;
        if (constraints.maxWidth < 680) {
          crossAxisCount = 1;
        } else if (constraints.maxWidth < 1040) {
          crossAxisCount = 2;
        }

        // 아이템의 최소 너비 기반 종횡비 계산 (오버플로우 원천 방지)
        final double itemWidth =
            (constraints.maxWidth - ((crossAxisCount - 1) * 16)) /
            crossAxisCount;
        // 카드의 높이는 약 230px 필요
        final double childAspectRatio = (itemWidth / 235).clamp(1.15, 2.2);

        final totalCards = _peers.length < 3 ? 3 : _peers.length;

        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: totalCards,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: 16,
            mainAxisSpacing: 16,
            childAspectRatio: childAspectRatio,
          ),
          itemBuilder: (context, index) {
            if (index < _peers.length) {
              return _buildPeerCard(_peers[index], index == 0);
            } else {
              return _buildWaitingSlotCard(index + 1);
            }
          },
        );
      },
    );
  }

  Widget _buildWaitingSlotCard(int slotNum) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF232428).withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFF3F4147),
          width: 1.5,
          strokeAlign: BorderSide.strokeAlignCenter,
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: const BoxDecoration(
              color: Color(0xFF2B2D31),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.person_add_alt_1,
              color: Color(0xFF80848E),
              size: 22,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '참여자 $slotNum 대기 중',
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 14,
              color: Color(0xFF949BA4),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '방 번호 #${_audioEngine.roomId} 참가 대기',
            style: const TextStyle(color: Color(0xFF5C5E66), fontSize: 11),
          ),
          const SizedBox(height: 8),
          Text(
            widget.isJamming ? 'UDP 신호 대기 중...' : '오프라인',
            style: TextStyle(
              color: widget.isJamming
                  ? const Color(0xFF23A55A)
                  : const Color(0xFF5C5E66),
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPeerCard(PeerState peer, bool isMe) {
    final double level = isMe
        ? (widget.isJamming ? _audioEngine.inputLevel : 0.0)
        : (widget.isJamming ? _audioEngine.outputLevel : 0.0);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF2B2D31),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: widget.isJamming && !peer.isMuted
              ? const Color(0xFF23A55A).withValues(alpha: 0.6)
              : const Color(0xFF35363C),
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // 상단: 아바타 + 이름 + 악기 + 뮤트 버튼
          Row(
            children: [
              Stack(
                alignment: Alignment.bottomRight,
                children: [
                  CircleAvatar(
                    radius: 22,
                    backgroundColor: isMe
                        ? const Color(0xFF5865F2)
                        : const Color(0xFF4E5058),
                    child: Icon(
                      isMe ? Icons.person : Icons.audiotrack,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: widget.isJamming && !peer.isMuted
                          ? const Color(0xFF23A55A)
                          : const Color(0xFF80848E),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: const Color(0xFF2B2D31),
                        width: 2,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      peer.name,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      peer.instrument,
                      style: const TextStyle(
                        color: Color(0xFF949BA4),
                        fontSize: 11,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(
                  peer.isMuted ? Icons.volume_off : Icons.volume_up,
                  color: peer.isMuted
                      ? const Color(0xFFF23F43)
                      : const Color(0xFFB5BAC1),
                  size: 20,
                ),
                onPressed: () {
                  setState(() {
                    peer.isMuted = !peer.isMuted;
                    if (peer.isMuted) {
                      _audioEngine.setChannelVolume(peer.userId, 0.0);
                    } else {
                      _audioEngine.setChannelVolume(peer.userId, peer.volume);
                    }
                  });
                },
                tooltip: peer.isMuted ? '음소거 해제' : '음소거',
              ),
            ],
          ),

          // 중간: 실시간 VU 레벨 미터 (애니메이션 바)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    peer.audioInterface,
                    style: const TextStyle(
                      color: Color(0xFF80848E),
                      fontSize: 10,
                    ),
                  ),
                  Text(
                    widget.isJamming ? (isMe ? '입력 신호' : '수신 신호') : '대기 중',
                    style: TextStyle(
                      color: widget.isJamming
                          ? const Color(0xFF23A55A)
                          : const Color(0xFF80848E),
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Container(
                  height: 8,
                  color: const Color(0xFF1E1F22),
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: peer.isMuted ? 0.0 : level.clamp(0.0, 1.0),
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: level > 0.85
                              ? [
                                  const Color(0xFF23A55A),
                                  Colors.amber,
                                  const Color(0xFFF23F43),
                                ]
                              : [
                                  const Color(0xFF23A55A),
                                  const Color(0xFF57F287),
                                ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),

          // 하단: 볼륨 슬라이더
          Row(
            children: [
              const Text(
                'VOL',
                style: TextStyle(
                  color: Color(0xFF80848E),
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 4,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 12,
                    ),
                    activeTrackColor: const Color(0xFF5865F2),
                    inactiveTrackColor: const Color(0xFF383A40),
                    thumbColor: Colors.white,
                  ),
                  child: Slider(
                    value: peer.isMuted ? 0.0 : peer.volume,
                    min: 0.0,
                    max: 1.5,
                    onChanged: (val) {
                      setState(() {
                        peer.volume = val;
                        peer.isMuted = (val == 0.0);
                        if (isMe) {
                          _audioEngine.setInputGain(val);
                        } else {
                          _audioEngine.setChannelVolume(peer.userId, val);
                        }
                      });
                    },
                  ),
                ),
              ),
              Text(
                '${(peer.volume * 100).toInt()}%',
                style: const TextStyle(color: Color(0xFFB5BAC1), fontSize: 11),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
