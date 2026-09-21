import 'package:flutter/material.dart';

class JamScheduleItem {
  final String id;
  final String title;
  final String dateString;
  final String setlist;
  final List<String> confirmedMembers;
  final List<String> pendingMembers;

  JamScheduleItem({
    required this.id,
    required this.title,
    required this.dateString,
    required this.setlist,
    required this.confirmedMembers,
    required this.pendingMembers,
  });
}

class LobbyScreen extends StatefulWidget {
  const LobbyScreen({super.key});

  @override
  State<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends State<LobbyScreen> {

  // 합주 일정 목록 (초기화 완료, 새 일정 생성 시 추가됨)
  final List<JamScheduleItem> _schedules = [];

  final _titleController = TextEditingController();
  final _dateController = TextEditingController();
  final _setlistController = TextEditingController();

  void _showAddScheduleDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF2B2D31),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          title: const Text('새 합주 일정 추가', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          content: SingleChildScrollView(
            child: SizedBox(
              width: 400,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: _titleController,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      labelText: '합주 제목',
                      labelStyle: TextStyle(color: Color(0xFF949BA4)),
                      hintText: '예: 금요일 저녁 합주',
                      hintStyle: TextStyle(color: Color(0xFF5C5E66)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _dateController,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      labelText: '일시',
                      labelStyle: TextStyle(color: Color(0xFF949BA4)),
                      hintText: '예: 9월 26일 토요일 저녁 8시',
                      hintStyle: TextStyle(color: Color(0xFF5C5E66)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _setlistController,
                    maxLines: 3,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      labelText: '합주곡 (셋리스트)',
                      labelStyle: TextStyle(color: Color(0xFF949BA4)),
                      hintText: '연습할 곡 목록이나 링크를 적어주세요',
                      hintStyle: TextStyle(color: Color(0xFF5C5E66)),
                    ),
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
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF5865F2)),
              onPressed: () {
                if (_titleController.text.trim().isNotEmpty) {
                  setState(() {
                    _schedules.insert(
                      0,
                      JamScheduleItem(
                        id: DateTime.now().millisecondsSinceEpoch.toString(),
                        title: _titleController.text.trim(),
                        dateString: _dateController.text.trim().isEmpty ? '날짜 미정' : _dateController.text.trim(),
                        setlist: _setlistController.text.trim().isEmpty ? '자유 잼' : _setlistController.text.trim(),
                        confirmedMembers: ['의진 (나)'],
                        pendingMembers: ['친구 A', '친구 B'],
                      ),
                    );
                  });
                  _titleController.clear();
                  _dateController.clear();
                  _setlistController.clear();
                  Navigator.pop(context);
                }
              },
              child: const Text('일정 등록', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    _titleController.dispose();
    _dateController.dispose();
    _setlistController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 상단 타이틀 & 일정 등록 버튼
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text(
                    '합주 일정 조율 및 투표',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  SizedBox(height: 4),
                  Text(
                    '친구들과 합주 일정을 잡고 참석 여부를 확인하세요',
                    style: TextStyle(color: Color(0xFF949BA4), fontSize: 13),
                  ),
                ],
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF5865F2),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: _showAddScheduleDialog,
                icon: const Icon(Icons.add, color: Colors.white, size: 18),
                label: const Text('새 일정 생성', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // 일정 카드 목록 또는 빈 화면
          if (_schedules.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
              decoration: BoxDecoration(
                color: const Color(0xFF2B2D31),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF35363C)),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Icon(Icons.event_available, size: 48, color: Color(0xFF4E5058)),
                  SizedBox(height: 12),
                  Text(
                    '예정된 합주 일정이 없습니다.',
                    style: TextStyle(color: Color(0xFF949BA4), fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 6),
                  Text(
                    '우측 상단의 "+ 새 일정 생성" 버튼을 눌러 첫 합주 약속을 등록해보세요!',
                    style: TextStyle(color: Color(0xFF5C5E66), fontSize: 13),
                  ),
                ],
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _schedules.length,
              separatorBuilder: (context, index) => const SizedBox(height: 16),
              itemBuilder: (context, index) {
                final schedule = _schedules[index];
                return _buildScheduleCard(schedule);
              },
            ),
        ],
      ),
    );
  }

  Widget _buildScheduleCard(JamScheduleItem schedule) {
    final bool isMyConfirmed = schedule.confirmedMembers.contains('의진 (나)');

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF2B2D31),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF35363C)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  schedule.title,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: isMyConfirmed
                      ? const Color(0xFF23A55A).withValues(alpha: 0.15)
                      : const Color(0xFFF23F43).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  isMyConfirmed ? '참가 확정됨' : '미확정',
                  style: TextStyle(
                    color: isMyConfirmed ? const Color(0xFF23A55A) : const Color(0xFFF23F43),
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.calendar_month, color: Color(0xFF5865F2), size: 16),
              const SizedBox(width: 6),
              Text(
                schedule.dateString,
                style: const TextStyle(color: Color(0xFFDBDEE1), fontSize: 13, fontWeight: FontWeight.w500),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1F22),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '🎸 셋리스트 (합주곡):',
                  style: TextStyle(color: Color(0xFF949BA4), fontSize: 12, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  schedule.setlist,
                  style: const TextStyle(color: Color(0xFFDBDEE1), fontSize: 13, height: 1.4),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // 참여 인원 현황
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text(
                '참석자:',
                style: TextStyle(color: Color(0xFF949BA4), fontSize: 12, fontWeight: FontWeight.bold),
              ),
              ...schedule.confirmedMembers.map(
                (m) => Chip(
                  backgroundColor: const Color(0xFF23A55A).withValues(alpha: 0.2),
                  side: const BorderSide(color: Color(0xFF23A55A)),
                  avatar: const Icon(Icons.check, size: 14, color: Color(0xFF23A55A)),
                  label: Text(m, style: const TextStyle(color: Colors.white, fontSize: 11)),
                  visualDensity: VisualDensity.compact,
                ),
              ),
              ...schedule.pendingMembers.map(
                (m) => Chip(
                  backgroundColor: const Color(0xFF4E5058).withValues(alpha: 0.3),
                  side: const BorderSide(color: Color(0xFF4E5058)),
                  avatar: const Icon(Icons.hourglass_empty, size: 14, color: Color(0xFF949BA4)),
                  label: Text(m, style: const TextStyle(color: Color(0xFF949BA4), fontSize: 11)),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // 투표 버튼
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFB5BAC1),
                  side: const BorderSide(color: Color(0xFF4E5058)),
                ),
                onPressed: () {
                  setState(() {
                    schedule.confirmedMembers.remove('의진 (나)');
                    if (!schedule.pendingMembers.contains('의진 (나)')) {
                      schedule.pendingMembers.add('의진 (나)');
                    }
                  });
                },
                icon: const Icon(Icons.close, size: 16),
                label: const Text('불참 / 미정'),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF23A55A),
                  foregroundColor: Colors.white,
                ),
                onPressed: () {
                  setState(() {
                    schedule.pendingMembers.remove('의진 (나)');
                    if (!schedule.confirmedMembers.contains('의진 (나)')) {
                      schedule.confirmedMembers.add('의진 (나)');
                    }
                  });
                },
                icon: const Icon(Icons.check, size: 16),
                label: const Text('참가 투표 완료'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}