import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'user_service.dart';

class DeepLinkData {
  final String userName;
  final String userId;
  final int roomId;
  final String roomName;
  final bool isHost;
  final String? hostIp;
  final int port;
  final String? ztNetworkId;
  final String rawUrl;

  const DeepLinkData({
    required this.userName,
    required this.userId,
    this.roomId = 1,
    this.roomName = '합주실',
    this.isHost = false,
    this.hostIp,
    this.port = 9999,
    this.ztNetworkId,
    required this.rawUrl,
  });

  @override
  String toString() =>
      'DeepLinkData(user: $userName, uid: $userId, room: #$roomId ($roomName), isHost: $isHost, ztNet: $ztNetworkId, hostIp: $hostIp:$port)';
}

class DeepLinkService {
  static final DeepLinkService _instance = DeepLinkService._internal();
  factory DeepLinkService() => _instance;
  DeepLinkService._internal();

  static const MethodChannel _channel = MethodChannel('com.example.gam/deeplink');

  final ValueNotifier<DeepLinkData?> sessionNotifier = ValueNotifier<DeepLinkData?>(null);
  DeepLinkData? get currentSession => sessionNotifier.value;
  bool get hasSession => currentSession != null;

  bool _initialized = false;

  Future<void> init(List<String> launchArgs) async {
    if (_initialized) return;
    _initialized = true;

    // 1. Windows 또는 CLI 아규먼트로부터 gam:// URL 확인
    for (final arg in launchArgs) {
      if (arg.startsWith('gam://')) {
        debugPrint('[DeepLink] Found URL in CLI args: $arg');
        _handleIncomingUrl(arg);
        break;
      }
    }

    // 2. macOS 네이티브 채널에서 초기 URL 확인 및 이벤트 리스너 등록
    if (Platform.isMacOS) {
      try {
        _channel.setMethodCallHandler((call) async {
          if (call.method == 'onDeepLink') {
            final url = call.arguments as String?;
            if (url != null && url.isNotEmpty) {
              debugPrint('[DeepLink] Incoming deep link via native channel: $url');
              _handleIncomingUrl(url);
            }
          }
        });

        final initialUrl = await _channel.invokeMethod<String>('getInitialUrl');
        if (initialUrl != null && initialUrl.isNotEmpty) {
          debugPrint('[DeepLink] Initial URL received from native: $initialUrl');
          _handleIncomingUrl(initialUrl);
        }
      } catch (e) {
        debugPrint('[DeepLink] Native channel init notice: $e');
      }
    }

    // 3. Windows 환경인 경우 gam:// 프로토콜 핸들러를 레지스트리에 자동 등록
    if (Platform.isWindows) {
      _registerWindowsProtocol();
    }
  }

  void _handleIncomingUrl(String rawUrl) {
    try {
      final data = parseUrl(rawUrl);
      if (data != null) {
        sessionNotifier.value = data;
        if (data.isHost && data.userName.isNotEmpty) {
          UserService().setProfile(nickname: data.userName, uid: data.userId);
        }
        debugPrint('[DeepLink] Activated session: $data');
      }
    } catch (e) {
      debugPrint('[DeepLink] Failed to parse URL: $e');
    }
  }

  DeepLinkData? parseUrl(String rawUrl) {
    try {
      final uri = Uri.parse(rawUrl);
      if (uri.scheme != 'gam') return null;

      final params = uri.queryParameters;
      final rawUser = params['user'] ?? params['nickname'] ?? params['username'];
      final userName = rawUser != null && rawUser.trim().isNotEmpty
          ? rawUser.trim()
          : (UserService().hasNickname ? UserService().nickname : '게스트');

      final rawUid = params['uid'] ?? params['id'];
      final userId = rawUid != null && rawUid.trim().isNotEmpty
          ? rawUid.trim()
          : (UserService().uid.isNotEmpty ? UserService().uid : 'guest_${userName.hashCode.abs()}');

      final roomId = int.tryParse(params['roomId'] ?? params['room'] ?? '') ?? 1;
      final rawRoomName = params['roomName'] ?? params['room_name'] ?? params['name'] ?? params['title'];
      final roomName = rawRoomName != null && rawRoomName.trim().isNotEmpty
          ? rawRoomName.trim()
          : '합주실 #$roomId';

      final isHost = (params['isHost'] ?? params['host'] ?? 'false').toLowerCase() == 'true';
      final hostIp = params['ip'] ?? params['hostIp'];
      final port = int.tryParse(params['port'] ?? '') ?? 9999;
      final ztNet = params['ztNet'] ?? params['networkId'] ?? params['zt'];

      return DeepLinkData(
        userName: userName,
        userId: userId,
        roomId: roomId,
        roomName: roomName,
        isHost: isHost,
        hostIp: hostIp,
        port: port,
        ztNetworkId: ztNet != null && ztNet.trim().isNotEmpty ? ztNet.trim() : null,
        rawUrl: rawUrl,
      );
    } catch (e) {
      debugPrint('[DeepLink] Parse error: $e');
      return null;
    }
  }

  /// Windows Registry에 gam:// 프로토콜 등록 (HKCU\Software\Classes\gam)
  Future<void> _registerWindowsProtocol() async {
    try {
      final exePath = Platform.resolvedExecutable;
      await Process.run('reg', [
        'add',
        r'HKCU\Software\Classes\gam',
        '/ve',
        '/d',
        'URL:gam Protocol',
        '/f'
      ]);
      await Process.run('reg', [
        'add',
        r'HKCU\Software\Classes\gam',
        '/v',
        'URL Protocol',
        '/d',
        '',
        '/f'
      ]);
      await Process.run('reg', [
        'add',
        r'HKCU\Software\Classes\gam\shell\open\command',
        '/ve',
        '/d',
        '"$exePath" "%1"',
        '/f'
      ]);
      debugPrint('[DeepLink] Windows protocol handler registered for gam://');
    } catch (e) {
      debugPrint('[DeepLink] Windows protocol registration notice: $e');
    }
  }
}
