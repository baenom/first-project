import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:gam/firebase_options.dart';
import 'screens/login_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
      home: const LoginScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}