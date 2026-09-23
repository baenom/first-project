import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:gam/firebase_options.dart';
import 'screens/login_screen.dart';
import 'screens/main_lobby_screen.dart';

import 'services/deep_link_service.dart';

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // 딥링크 서비스 초기화 (Windows CLI args 및 macOS MethodChannel)
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
          // 디스코드 딥링크로 접속한 경우 키체인/로그인 없이 즉시 로비/합주실 진입
          if (deepLinkSession != null) {
            return const MainLobbyScreen();
          }

          bool isFirebaseInitialized = false;
          try {
            isFirebaseInitialized = Firebase.apps.isNotEmpty;
          } catch (_) {
            isFirebaseInitialized = false;
          }

          if (isFirebaseInitialized) {
            return StreamBuilder<User?>(
              stream: FirebaseAuth.instance.authStateChanges(),
              initialData: FirebaseAuth.instance.currentUser,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
                  return const Scaffold(
                    backgroundColor: Color(0xFF1E1F22),
                    body: Center(
                      child: CircularProgressIndicator(color: Color(0xFF5865F2)),
                    ),
                  );
                }
                if (snapshot.hasData && snapshot.data != null) {
                  return const MainLobbyScreen();
                }
                return const LoginScreen();
              },
            );
          }

          return const LoginScreen();
        },
      ),
      debugShowCheckedModeBanner: false,
    );
  }
}