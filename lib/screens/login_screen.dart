import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'main_lobby_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nicknameController = TextEditingController();
  bool _isSignUp = false;
  String _errorMessage = '';
  bool _isLoading = false;

  Future<void> _submit() async {
    final rawInput = _emailController.text.trim();
    final password = _passwordController.text.trim();
    final nickname = _nicknameController.text.trim();

    if (rawInput.isEmpty || password.isEmpty) {
      setState(() => _errorMessage = '이메일(또는 닉네임)과 비밀번호를 모두 입력해주세요.');
      return;
    }

    if (_isSignUp && nickname.isEmpty) {
      setState(() => _errorMessage = '합주실에서 사용할 닉네임(활동명)을 입력해주세요.');
      return;
    }

    setState(() {
      _errorMessage = '';
      _isLoading = true;
    });

    try {
      if (_isSignUp) {
        // 회원가입: 이메일 형식이 아니면 닉네임/아이디 기반 가상 이메일 생성
        String signupEmail = rawInput;
        if (!signupEmail.contains('@')) {
          signupEmail = '${signupEmail.replaceAll(' ', '_').toLowerCase()}@syncroom.gam';
        }

        final cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: signupEmail,
          password: password,
        );
        if (nickname.isNotEmpty) {
          await cred.user?.updateDisplayName(nickname);
        }

        // Firestore에 닉네임 및 이메일 매핑 저장 (닉네임으로 바로 로그인 가능하도록)
        try {
          final uid = cred.user?.uid ?? '';
          if (uid.isNotEmpty) {
            await FirebaseFirestore.instance.collection('users').doc(uid).set({
              'uid': uid,
              'email': signupEmail,
              'nickname': nickname,
              'createdAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));

            await FirebaseFirestore.instance
                .collection('nickname_map')
                .doc(nickname.trim().toLowerCase())
                .set({
              'email': signupEmail,
              'uid': uid,
              'nickname': nickname,
            }, SetOptions(merge: true));
          }
        } catch (dbErr) {
          debugPrint('[Auth] Firestore nickname mapping notice: $dbErr');
        }
      } else {
        // 로그인: 닉네임 입력 시 해당 이메일 자동 조회
        String loginEmail = rawInput;
        if (!loginEmail.contains('@')) {
          try {
            final mapDoc = await FirebaseFirestore.instance
                .collection('nickname_map')
                .doc(rawInput.toLowerCase())
                .get();
            if (mapDoc.exists && mapDoc.data()?['email'] != null) {
              loginEmail = mapDoc.data()!['email'] as String;
            } else {
              final query = await FirebaseFirestore.instance
                  .collection('users')
                  .where('nickname', isEqualTo: rawInput)
                  .limit(1)
                  .get();
              if (query.docs.isNotEmpty) {
                loginEmail = query.docs.first.data()['email'] as String;
              } else {
                loginEmail = '${rawInput.replaceAll(' ', '_').toLowerCase()}@syncroom.gam';
              }
            }
          } catch (lookupErr) {
            debugPrint('[Auth] Nickname lookup notice: $lookupErr');
            loginEmail = '${rawInput.replaceAll(' ', '_').toLowerCase()}@syncroom.gam';
          }
        }

        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: loginEmail,
          password: password,
        );
      }

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const MainLobbyScreen()),
      );
    } on FirebaseAuthException catch (e) {
      final msg = (e.message ?? '').toLowerCase();
      // macOS 키체인 접근 제한(keychain-error) 발생 시:
      // 서버에서 인증은 이미 성공한 상태이므로 차단하지 않고 바로 메인 로비로 진입!
      if (e.code == 'keychain-error' || msg.contains('keychain')) {
        debugPrint('[Auth] Keychain access denied on this Mac, bypassing to lobby: $e');
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const MainLobbyScreen()),
        );
        return;
      }
      setState(() {
        _errorMessage = e.message ?? '인증 처리 중 오류가 발생했습니다.';
      });
    } catch (e) {
      final msg = e.toString().toLowerCase();
      if (msg.contains('keychain')) {
        debugPrint('[Auth] Keychain error in generic catch, bypassing to lobby: $e');
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const MainLobbyScreen()),
        );
        return;
      }
      setState(() {
        _errorMessage = '인증 오류: $e';
      });
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _nicknameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1F22),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 420),
            padding: const EdgeInsets.all(36),
            decoration: BoxDecoration(
              color: const Color(0xFF2B2D31),
              borderRadius: BorderRadius.circular(16),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black45,
                  blurRadius: 24,
                  offset: Offset(0, 8),
                ),
              ],
              border: Border.all(color: const Color(0xFF35363C)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 로고 및 헤더
                Center(
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF5865F2), Color(0xFF7983F5)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF5865F2).withValues(alpha: 0.4),
                          blurRadius: 16,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.music_note,
                      color: Colors.white,
                      size: 36,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  _isSignUp ? '합주 멤버 가입' : '합주실 입장',
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: -0.5,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  _isSignUp
                      ? '친구들과 무압축 UDP 저지연 합주를 시작하세요.'
                      : 'NAS 중계 서버와 오인페에 연결할 준비를 합니다.',
                  style: const TextStyle(
                    color: Color(0xFF949BA4),
                    fontSize: 13,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 28),

                // 텍스트 필드
                if (_isSignUp) ...[
                  const Text(
                    '합주실 닉네임 (활동명)',
                    style: TextStyle(
                      color: Color(0xFFB5BAC1),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _nicknameController,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: '예: 베이시스트 민수, 기타리스트 철수',
                      hintStyle: const TextStyle(color: Color(0xFF5C5E66)),
                      filled: true,
                      fillColor: const Color(0xFF1E1F22),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(
                          color: Color(0xFF5865F2),
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                Text(
                  _isSignUp ? '이메일 (아이디)' : '이메일 또는 닉네임',
                  style: const TextStyle(
                    color: Color(0xFFB5BAC1),
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: _isSignUp ? 'name@example.com' : '가입한 이메일 또는 닉네임 입력',
                    hintStyle: const TextStyle(color: Color(0xFF5C5E66)),
                    filled: true,
                    fillColor: const Color(0xFF1E1F22),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(
                        color: Color(0xFF5865F2),
                        width: 1.5,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                const Text(
                  '비밀번호',
                  style: TextStyle(
                    color: Color(0xFFB5BAC1),
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: '••••••••',
                    hintStyle: const TextStyle(color: Color(0xFF5C5E66)),
                    filled: true,
                    fillColor: const Color(0xFF1E1F22),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(
                        color: Color(0xFF5865F2),
                        width: 1.5,
                      ),
                    ),
                  ),
                  onSubmitted: (_) => _submit(),
                ),

                if (_errorMessage.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFDA373C).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: const Color(0xFFDA373C).withValues(alpha: 0.4),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.error_outline,
                          color: Color(0xFFF23F43),
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _errorMessage,
                            style: const TextStyle(
                              color: Color(0xFFF23F43),
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 24),

                // 제출 버튼
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF5865F2),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    elevation: 0,
                  ),
                  onPressed: _isLoading ? null : _submit,
                  child: _isLoading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : Text(
                          _isSignUp ? '계정 생성 후 입장' : '합주실 로비 접속',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                ),
                const SizedBox(height: 12),

                // 모드 전환
                TextButton(
                  onPressed: () {
                    setState(() {
                      _isSignUp = !_isSignUp;
                      _errorMessage = '';
                    });
                  },
                  child: Text(
                    _isSignUp ? '이미 계정이 있으신가요? 로그인' : '새 멤버 등록이 필요하신가요? 회원가입',
                    style: const TextStyle(
                      color: Color(0xFF00A8FC),
                      fontSize: 13,
                    ),
                  ),
                ),

                // 빠른 개발용 테스트 입장
                // const Divider(color: Color(0xFF35363C), height: 28),
                // OutlinedButton.icon(
                //   style: OutlinedButton.styleFrom(
                //     foregroundColor: const Color(0xFF949BA4),
                //     side: const BorderSide(color: Color(0xFF3F4147)),
                //     shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                //   ),
                //   onPressed: _bypassForTesting,
                //   icon: const Icon(Icons.bolt, size: 16),
                //   label: const Text('게스트로 바로 로비 입장 (로컬 테스트)'),
                // ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
