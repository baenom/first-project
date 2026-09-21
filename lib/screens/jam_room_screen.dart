import 'package:flutter/material.dart';
import '../services/audio_engine.dart';

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

  const JamRoomScreen({
    super.key,
    required this.onToggleJam,
    required this.isJamming,
    required this.onOpenSettings,
  });

  @override
  State<JamRoomScreen> createState() => _JamRoomScreenState();
}

class _JamRoomScreenState extends State<JamRoomScreen> {
  final AudioEngine _audioEngine = AudioEngine();

  late final List<PeerState> _peers;

  @override
  void initState() {
    super.initState();
    _peers = [
      PeerState(
        userId: _audioEngine.userId,
        name: '의진 (나)',
        instrument: '내 악기 / 오디오 인터페이스',
        audioInterface: 'ASIO / CoreAudio 연결됨',
      ),
    ];
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
                  color: widget.isJamming ? const Color(0xFF23A55A) : const Color(0xFF949BA4),
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        '서울-경기 무압축 UDP 합주실',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
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
                    style: const TextStyle(color: Color(0xFF949BA4), fontSize: 12),
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
                  foregroundColor: const Color(0xFFDBDEE1),
                  side: const BorderSide(color: Color(0xFF4E5058)),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
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
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
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
    final totalLatency = (_audioEngine.currentRtt + double.parse(bufferMs)).toStringAsFixed(1);

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
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '오인페 버퍼:',
                style: TextStyle(color: Color(0xFF949BA4), fontSize: 13, fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: 8),
              _buildBufferChip(64, '64 samples (1.3ms)'),
              const SizedBox(width: 6),
              _buildBufferChip(128, '128 samples (2.7ms)'),
              const SizedBox(width: 6),
              _buildBufferChip(256, '256 samples (5.3ms)'),
            ],
          ),

          // 레이턴시 측정 지표
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.speed, color: Color(0xFF23A55A), size: 18),
              const SizedBox(width: 6),
              Text(
                'RTT 네트워크: ${_audioEngine.currentRtt.toStringAsFixed(1)}ms',
                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF23A55A).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '체감 총 지연: 약 $totalLatency ms (연주 동기화 최적)',
                  style: const TextStyle(color: Color(0xFF23A55A), fontSize: 12, fontWeight: FontWeight.bold),
                ),
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
            color: isSelected ? const Color(0xFF5865F2) : const Color(0xFF3F4147),
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
        final double itemWidth = (constraints.maxWidth - ((crossAxisCount - 1) * 16)) / crossAxisCount;
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
            child: const Icon(Icons.person_add_alt_1, color: Color(0xFF80848E), size: 22),
          ),
          const SizedBox(height: 10),
          Text(
            '참여자 $slotNum 대기 중',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF949BA4)),
          ),
          const SizedBox(height: 4),
          Text(
            '방 번호 #${_audioEngine.roomId} 참가 대기',
            style: const TextStyle(color: Color(0xFF5C5E66), fontSize: 11),
          ),
          const SizedBox(height: 8),
          Text(
            widget.isJamming ? '● UDP 신호 대기 중...' : '○ 오프라인',
            style: TextStyle(
              color: widget.isJamming ? const Color(0xFF23A55A) : const Color(0xFF5C5E66),
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
                    backgroundColor: isMe ? const Color(0xFF5865F2) : const Color(0xFF4E5058),
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
                      border: Border.all(color: const Color(0xFF2B2D31), width: 2),
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
                      style: const TextStyle(color: Color(0xFF949BA4), fontSize: 11),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(
                  peer.isMuted ? Icons.volume_off : Icons.volume_up,
                  color: peer.isMuted ? const Color(0xFFF23F43) : const Color(0xFFB5BAC1),
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
                    style: const TextStyle(color: Color(0xFF80848E), fontSize: 10),
                  ),
                  Text(
                    widget.isJamming
                        ? (isMe ? '입력 신호' : '수신 신호')
                        : '대기 중',
                    style: TextStyle(
                      color: widget.isJamming ? const Color(0xFF23A55A) : const Color(0xFF80848E),
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
                              ? [const Color(0xFF23A55A), Colors.amber, const Color(0xFFF23F43)]
                              : [const Color(0xFF23A55A), const Color(0xFF57F287)],
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
                style: TextStyle(color: Color(0xFF80848E), fontSize: 11, fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 4,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
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