import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// 무가입 원클릭 게스트 로그인 및 로컬 프로필 관리 서비스
class UserService {
  static final UserService _instance = UserService._internal();
  factory UserService() => _instance;
  UserService._internal();

  final ValueNotifier<String?> currentNickname = ValueNotifier<String?>(null);
  String _uid = '';

  String get nickname => currentNickname.value ?? '게스트';
  String get uid =>
      _uid.isNotEmpty ? _uid : 'guest_${nickname.hashCode.abs() % 100000}';

  bool get hasNickname =>
      currentNickname.value != null &&
      currentNickname.value!.trim().isNotEmpty;

  File _getConfigFile() {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    return File('$home/.gam_guest_profile.json');
  }

  /// 앱 시작 시 저장된 게스트 닉네임 로드
  Future<void> loadProfile() async {
    try {
      final f = _getConfigFile();
      if (await f.exists()) {
        final content = await f.readAsString();
        final data = jsonDecode(content);
        if (data['nickname'] != null &&
            data['nickname'].toString().trim().isNotEmpty) {
          currentNickname.value = data['nickname'].toString().trim();
        }
        if (data['uid'] != null) {
          _uid = data['uid'].toString();
        }
        debugPrint(
            '[UserService] Loaded saved guest profile: ${currentNickname.value} (UID: $_uid)');
      }
    } catch (e) {
      debugPrint('[UserService] Load profile notice: $e');
    }
  }

  /// 닉네임 설정 및 영구 저장 (회원가입/비밀번호 불필요)
  Future<void> setProfile({required String nickname, String? uid}) async {
    final cleanName = nickname.trim();
    currentNickname.value = cleanName;

    if (uid != null && uid.isNotEmpty) {
      _uid = uid;
    } else if (_uid.isEmpty) {
      _uid = 'guest_${cleanName.hashCode.abs() % 100000}';
    }

    try {
      final f = _getConfigFile();
      await f.writeAsString(jsonEncode({
        'nickname': cleanName,
        'uid': _uid,
      }));
    } catch (e) {
      debugPrint('[UserService] Save profile notice: $e');
    }

    // 백그라운드 Firebase 익명 인증 (Firestore 실시간 방 목록/채팅 권한 유지)
    _syncAnonymousAuth(cleanName);
  }

  /// 프로필 초기화 (로그아웃 시)
  Future<void> clearProfile() async {
    currentNickname.value = null;
    _uid = '';
    try {
      final f = _getConfigFile();
      if (await f.exists()) {
        await f.delete();
      }
    } catch (_) {}

    try {
      if (Firebase.apps.isNotEmpty) {
        await FirebaseAuth.instance.signOut();
      }
    } catch (_) {}
  }

  void _syncAnonymousAuth(String name) {
    try {
      if (Firebase.apps.isNotEmpty) {
        final current = FirebaseAuth.instance.currentUser;
        if (current == null) {
          FirebaseAuth.instance.signInAnonymously().then((cred) {
            cred.user?.updateDisplayName(name).catchError((_) {});
          }).catchError((e) {
            debugPrint('[UserService] Silent anonymous auth notice: $e');
          });
        } else {
          current.updateDisplayName(name).catchError((_) {});
        }
      }
    } catch (_) {}
  }
}
