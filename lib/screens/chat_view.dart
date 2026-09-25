import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/user_service.dart';
import '../services/deep_link_service.dart';

class ChatView extends StatefulWidget {
  final String roomId;
  final String roomName;

  const ChatView({super.key, this.roomId = '1', this.roomName = '합주실'});

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  bool get _isFirebaseReady {
    try {
      return Firebase.apps.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  User? get _currentUser {
    try {
      if (_isFirebaseReady) {
        return FirebaseAuth.instance.currentUser;
      }
    } catch (_) {}
    return null;
  }

  String _getSenderName([User? user]) {
    final deepLink = DeepLinkService().currentSession;
    if (deepLink != null && deepLink.userName.isNotEmpty) {
      return deepLink.userName;
    }
    final guestName = UserService().nickname;
    if (guestName.isNotEmpty && guestName != '게스트') {
      return guestName;
    }
    final u = user ?? _currentUser;
    if (u?.displayName != null && u!.displayName!.trim().isNotEmpty) {
      return u.displayName!;
    }
    if (u?.email != null && u!.email!.trim().isNotEmpty) {
      return u.email!.split('@').first;
    }
    return guestName.isNotEmpty ? guestName : '합주자';
  }

  // 로컬 폴백 메시지 목록 (네트워크 단절 시 임시 보관)
  final List<Map<String, dynamic>> _fallbackMessages = [];
  bool _isSending = false;

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _isSending) return;
    _messageController.clear();

    setState(() => _isSending = true);

    try {
      if (!_isFirebaseReady) {
        throw Exception('Firebase가 초기화되지 않았습니다.');
      }
      final user = _currentUser;
      final senderName = _getSenderName(user);
      final senderUid = (user?.uid != null && user!.uid.isNotEmpty)
          ? user.uid
          : UserService().uid;
      await FirebaseFirestore.instance
          .collection('jam_rooms')
          .doc(widget.roomId)
          .collection('chats')
          .add({
            'text': text,
            'sender': senderName,
            'senderEmail': user?.email ?? '',
            'userId': senderUid,
            'timestamp': FieldValue.serverTimestamp(),
            'createdAt': DateTime.now().millisecondsSinceEpoch,
          });

      debugPrint('[Firestore] Message successfully sent: $text');
    } catch (e, stack) {
      debugPrint('[Firestore Error] Failed to send message: $e\n$stack');
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.cloud_off, color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Expanded(child: Text('Firebase 채팅 업로드 실패: $e')),
              ],
            ),
            backgroundColor: const Color(0xFFDA373C),
            duration: const Duration(seconds: 4),
          ),
        );
      }
      setState(() {
        _fallbackMessages.add({
          'sender': _getSenderName(_currentUser),
          'text': text,
          'time': '로컬 보관 (업로드 실패)',
          'isMe': true,
        });
      });
    } finally {
      if (mounted) setState(() => _isSending = false);
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
            children: [
              const Icon(Icons.tag, color: Color(0xFF80848E), size: 20),
              const SizedBox(width: 8),
              Text(
                '${widget.roomName} 합주실 채팅',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  fontSize: 14,
                ),
              ),
              const SizedBox(width: 12),
              const Text(
                '|  합주곡 악보, 코드 진행, 유튜브 링크를 공유하세요',
                style: TextStyle(color: Color(0xFF80848E), fontSize: 12),
              ),
            ],
          ),
        ),

        // 메시지 리스트 영역
        Expanded(
          child: !_isFirebaseReady
              ? _buildMessageListView(
                  _fallbackMessages.reversed.toList(),
                  isFallback: true,
                )
              : StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('jam_rooms')
                      .doc(widget.roomId)
                      .collection('chats')
                      .orderBy('createdAt', descending: true)
                      .limit(60)
                      .snapshots(),
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      debugPrint('[Firestore Chat Error] ${snapshot.error}');
                      return Column(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            color: const Color(
                              0xFFDA373C,
                            ).withValues(alpha: 0.2),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.cloud_off,
                                  color: Color(0xFFF23F43),
                                  size: 16,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Firebase 연결 오류: ${snapshot.error}',
                                    style: const TextStyle(
                                      color: Color(0xFFF23F43),
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: _buildMessageListView(
                              _fallbackMessages.reversed.toList(),
                              isFallback: true,
                            ),
                          ),
                        ],
                      );
                    }

                    if (snapshot.connectionState == ConnectionState.waiting &&
                        !snapshot.hasData) {
                      return const Center(
                        child: CircularProgressIndicator(
                          color: Color(0xFF5865F2),
                        ),
                      );
                    }

                    if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                      if (_fallbackMessages.isNotEmpty) {
                        return _buildMessageListView(
                          _fallbackMessages.reversed.toList(),
                          isFallback: true,
                        );
                      }
                      return _buildEmptyState();
                    }

                    final docs = snapshot.data!.docs;
                    final myUser = _currentUser;
                    final messages = docs.map((doc) {
                      final data = doc.data() as Map<String, dynamic>;
                      final sender = (data['sender'] as String?) ?? '익명';
                      final text = (data['text'] as String?) ?? '';
                      final senderEmail =
                          (data['senderEmail'] as String?) ?? '';
                      final userId = (data['userId'] as String?) ?? '';

                      final isMe = (userId.isNotEmpty &&
                              (userId == UserService().uid ||
                                  (myUser != null && myUser.uid == userId))) ||
                          (sender == _getSenderName(myUser));

                      String timeStr = '방금';
                      if (data['timestamp'] is Timestamp) {
                        final dt = (data['timestamp'] as Timestamp).toDate();
                        timeStr =
                            '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
                      } else if (data['createdAt'] is int) {
                        final dt = DateTime.fromMillisecondsSinceEpoch(
                          data['createdAt'] as int,
                        );
                        timeStr =
                            '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
                      }

                      return {
                        'sender': sender,
                        'text': text,
                        'time': timeStr,
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
                const Icon(
                  Icons.add_circle,
                  color: Color(0xFFB5BAC1),
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    decoration: const InputDecoration(
                      hintText: '#채팅 및 링크 공유 채널에 메시지 보내기...',
                      hintStyle: TextStyle(
                        color: Color(0xFF80848E),
                        fontSize: 13,
                      ),
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

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          Icon(Icons.chat_bubble_outline, size: 48, color: Color(0xFF4E5058)),
          SizedBox(height: 12),
          Text(
            '아직 메시지가 없습니다.',
            style: TextStyle(
              color: Color(0xFF949BA4),
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
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

  Widget _buildMessageListView(
    List<Map<String, dynamic>> messages, {
    required bool isFallback,
  }) {
    if (messages.isEmpty) {
      return _buildEmptyState();
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
                backgroundColor: isMe
                    ? const Color(0xFF5865F2)
                    : const Color(0xFF23A55A),
                child: Text(
                  sender.isNotEmpty ? sender[0].toUpperCase() : 'U',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
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
                            color: isMe
                                ? const Color(0xFF7983F5)
                                : Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          time,
                          style: const TextStyle(
                            color: Color(0xFF949BA4),
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      text,
                      style: const TextStyle(
                        color: Color(0xFFDBDEE1),
                        fontSize: 14,
                        height: 1.3,
                      ),
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
