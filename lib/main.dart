import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:gam/firebase_options.dart';
import 'screens/login_screen.dart';
import 'screens/main_lobby_screen.dart';

import 'services/deep_link_service.dart';
import 'services/user_service.dart';

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. 게스트 닉네임 프로필 로드
  await UserService().loadProfile();

  // 2. 딥링크 서비스 초기화 (Windows CLI args 및 macOS MethodChannel)
  await DeepLinkService().init(args);

  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    debugPrint("Firebase initialization info: $e");
  }

  runApp(const SyncRoomApp());
}

class SyncRoomApp extends StatelessWidget {
  const SyncRoomApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SyncRoom Private Jam',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF313338),
        primaryColor: const Color(0xFF5865F2),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF5865F2),
          secondary: Color(0xFF23A55A),
          surface: Color(0xFF2B2D31),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1E1F22),
          elevation: 0,
        ),
      ),
      home: ValueListenableBuilder<DeepLinkData?>(
        valueListenable: DeepLinkService().sessionNotifier,
        builder: (context, deepLinkSession, _) {
          // 1. 디스코드 딥링크로 접속한 경우: 회원가입/로그인 없이 즉시 로비/합주실 진입
          if (deepLinkSession != null) {
            return const MainLobbyScreen();
          }

          // 2. 게스트 닉네임이 이미 있는 경우: 묻지 않고 바로 로비 진입
          return ValueListenableBuilder<String?>(
            valueListenable: UserService().currentNickname,
            builder: (context, nickname, _) {
              if (nickname != null &&
                  nickname.trim().isNotEmpty &&
                  nickname != '게스트') {
                return const MainLobbyScreen();
              }
              // 3. 닉네임이 없으면 게스트 닉네임 설정 화면 표시
              return const LoginScreen();
            },
          );
        },
      ),
      debugShowCheckedModeBanner: false,
    );
  }
}