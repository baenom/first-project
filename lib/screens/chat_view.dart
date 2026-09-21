import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class ChatView extends StatefulWidget {
  const ChatView({super.key});

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final User? currentUser = FirebaseAuth.instance.currentUser;

  // 로컬 폴백 메시지 목록 (초기화 완료, 새 메시지 전송 시 추가됨)
  final List<Map<String, dynamic>> _fallbackMessages = [];

  void _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    _messageController.clear();

    try {
      await FirebaseFirestore.instance.collection('chats').add({
        'text': text,
        'sender': currentUser?.email?.split('@').first ?? '의진',
        'timestamp': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      // 오프라인 / 로컬 테스트 시 폴백 리스트에 추가
      setState(() {
        _fallbackMessages.add({
          'sender': currentUser?.email?.split('@').first ?? '의진',
          'text': text,
          'time': '방금',
          'isMe': true,
        });
      });
    }

    // 하단 스크롤
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          0.0,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 상단 채널 정보 바
        Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: const BoxDecoration(
            color: Color(0xFF313338),
            border: Border(bottom: BorderSide(color: Color(0xFF1F2023))),
          ),
          child: Row(
            children: const [
              Icon(Icons.tag, color: Color(0xFF80848E), size: 20),
              SizedBox(width: 8),
              Text(
                '채팅 및 링크 공유',
                style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 14),
              ),
              SizedBox(width: 12),
              Text(
                '|  합주곡 악보, 코드 진행, 유튜브 링크를 공유하세요',
                style: TextStyle(color: Color(0xFF80848E), fontSize: 12),
              ),
            ],
          ),
        ),

        // 메시지 리스트 영역
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('chats')
                .orderBy('timestamp', descending: true)
                .limit(50)
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.hasError || !snapshot.hasData || snapshot.data!.docs.isEmpty) {
                // 폴백 뷰 표시
                return _buildMessageListView(_fallbackMessages.reversed.toList(), isFallback: true);
              }

              final docs = snapshot.data!.docs;
              final messages = docs.map((doc) {
                final data = doc.data() as Map<String, dynamic>;
                final sender = data['sender'] ?? '알 수 없음';
                final text = data['text'] ?? '';
                final isMe = currentUser?.email?.startsWith(sender) ?? (sender == '의진');
                return {
                  'sender': sender,
                  'text': text,
                  'time': '실시간',
                  'isMe': isMe,
                };
              }).toList();

              return _buildMessageListView(messages, isFallback: false);
            },
          ),
        ),

        // 하단 입력창 영역
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: const Color(0xFF313338),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF383A40),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(Icons.add_circle, color: Color(0xFFB5BAC1), size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    decoration: const InputDecoration(
                      hintText: '#채팅 및 링크 공유 채널에 메시지 보내기...',
                      hintStyle: TextStyle(color: Color(0xFF80848E), fontSize: 13),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(vertical: 14),
                    ),
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send, color: Color(0xFF5865F2)),
                  onPressed: _sendMessage,
                  tooltip: '전송',
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMessageListView(List<Map<String, dynamic>> messages, {required bool isFallback}) {
    if (messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Icon(Icons.chat_bubble_outline, size: 48, color: Color(0xFF4E5058)),
            SizedBox(height: 12),
            Text(
              '아직 메시지가 없습니다.',
              style: TextStyle(color: Color(0xFF949BA4), fontSize: 15, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 4),
            Text(
              '첫 메시지를 입력하여 친구들과 대화를 시작해보세요!',
              style: TextStyle(color: Color(0xFF5C5E66), fontSize: 13),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      controller: _scrollController,
      reverse: true,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final msg = messages[index];
        final sender = msg['sender'] as String;
        final text = msg['text'] as String;
        final time = msg['time'] as String;
        final isMe = msg['isMe'] as bool;

        return Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: isMe ? const Color(0xFF5865F2) : const Color(0xFF23A55A),
                child: Text(
                  sender.isNotEmpty ? sender[0].toUpperCase() : 'U',
                  style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          sender,
                          style: TextStyle(
                            color: isMe ? const Color(0xFF7983F5) : Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          time,
                          style: const TextStyle(color: Color(0xFF949BA4), fontSize: 10),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      text,
                      style: const TextStyle(color: Color(0xFFDBDEE1), fontSize: 14, height: 1.3),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}