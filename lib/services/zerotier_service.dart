import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

class ZeroTierService {
  static final ZeroTierService _instance = ZeroTierService._internal();
  factory ZeroTierService() => _instance;
  ZeroTierService._internal();

  String? _cliPath;
  String? _apiToken;
  int _apiPort = 9993;
  bool _useApi = false;
  bool _detected = false;

  final ValueNotifier<String?> currentNetworkId = ValueNotifier<String?>(null);
  final ValueNotifier<String?> assignedVirtualIp = ValueNotifier<String?>(null);
  final ValueNotifier<bool> isConnecting = ValueNotifier<bool>(false);

  bool get isConnected => currentNetworkId.value != null && assignedVirtualIp.value != null;

  /// 로컬 컴퓨터에서 ZeroTier 연결 방식(REST API 또는 CLI) 감지
  Future<bool> detectService() async {
    if (_detected) return _useApi || _cliPath != null;
    _detected = true;

    // 1. ZeroTier Local REST API 시도 (관리자 권한 없이도 동작)
    _apiToken = await _findAuthToken();
    if (_apiToken != null && _apiToken!.isNotEmpty) {
      try {
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
        final req = await client.getUrl(Uri.parse('http://127.0.0.1:$_apiPort/status'));
        req.headers.set('X-ZT1-Auth', _apiToken!);
        final resp = await req.close();
        if (resp.statusCode == 200) {
          _useApi = true;
          debugPrint('[ZeroTier] Local REST API connected successfully (Port: $_apiPort)');
          client.close();
          return true;
        }
        client.close();
      } catch (e) {
        debugPrint('[ZeroTier] Local REST API probe failed: $e');
      }
    }

    // 2. Fallback: CLI 경로 감지 (macOS 또는 관리자 권한 터미널 환경)
    if (Platform.isMacOS) {
      final candidates = [
        '/usr/local/bin/zerotier-cli',
        '/Library/Application Support/ZeroTier/One/zerotier-cli',
        'zerotier-cli',
      ];
      for (final p in candidates) {
        if (p == 'zerotier-cli' || File(p).existsSync()) {
          try {
            final res = await Process.run(p, ['info']);
            if (res.exitCode == 0 || res.stdout.toString().contains('200 info')) {
              _cliPath = p;
              debugPrint('[ZeroTier] CLI found on macOS: $p');
              return true;
            }
          } catch (_) {}
        }
      }
    } else if (Platform.isWindows) {
      final candidates = [
        r'C:\ProgramData\ZeroTier\One\zerotier-cli.bat',
        r'C:\Program Files (x86)\ZeroTier\One\zerotier-cli.bat',
        r'C:\Program Files\ZeroTier\One\zerotier-cli.bat',
        'zerotier-cli',
      ];
      for (final p in candidates) {
        if (p == 'zerotier-cli' || File(p).existsSync()) {
          try {
            final res = await Process.run(p, ['info']);
            if (res.exitCode == 0 || res.stdout.toString().contains('200 info')) {
              _cliPath = p;
              debugPrint('[ZeroTier] CLI found on Windows: $p');
              return true;
            }
          } catch (_) {}
        }
      }
    }

    debugPrint('[ZeroTier] Neither REST API nor CLI detected.');
    return false;
  }

  /// 일반 사용자 권한으로 읽을 수 있는 authtoken.secret 파일 탐색
  Future<String?> _findAuthToken() async {
    final List<String> paths = [];

    if (Platform.isWindows) {
      final localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData != null) {
        paths.add('$localAppData\\ZeroTier\\authtoken.secret');
      }
      paths.add(r'C:\ProgramData\ZeroTier\One\authtoken.secret');
    } else if (Platform.isMacOS) {
      final home = Platform.environment['HOME'];
      if (home != null) {
        paths.add('$home/Library/Application Support/ZeroTier/One/authtoken.secret');
      }
      paths.add('/Library/Application Support/ZeroTier/One/authtoken.secret');
    } else {
      paths.add('/var/lib/zerotier-one/authtoken.secret');
    }

    for (final p in paths) {
      try {
        final file = File(p);
        if (await file.exists()) {
          final content = (await file.readAsString()).trim();
          if (content.isNotEmpty) {
            debugPrint('[ZeroTier] Found authtoken at: $p');
            return content;
          }
        }
      } catch (_) {}
    }

    return null;
  }

  /// 1회용 가상 네트워크에 자동 참여 (Join)
  Future<bool> joinNetwork(String networkId) async {
    if (networkId.isEmpty) return false;
    isConnecting.value = true;
    currentNetworkId.value = networkId;

    final isReady = await detectService();
    if (!isReady) {
      debugPrint('[ZeroTier] Cannot join: ZeroTier One is not running or not accessible.');
      isConnecting.value = false;
      return false;
    }

    try {
      debugPrint('[ZeroTier] Joining network: $networkId (via ${_useApi ? "REST API" : "CLI"})...');

      if (_useApi && _apiToken != null) {
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
        final req = await client.postUrl(Uri.parse('http://127.0.0.1:$_apiPort/network/$networkId'));
        req.headers.set('X-ZT1-Auth', _apiToken!);
        req.headers.contentType = ContentType.json;
        req.write('{}');
        final resp = await req.close();
        client.close();
        debugPrint('[ZeroTier] API Join response status: ${resp.statusCode}');
      } else if (_cliPath != null) {
        final joinRes = await Process.run(_cliPath!, ['join', networkId]);
        debugPrint('[ZeroTier] CLI Join response: ${joinRes.stdout}');
      }

      // IP가 할당될 때까지 최대 15초간 대기 (1초 간격 폴링)
      for (int i = 0; i < 15; i++) {
        await Future.delayed(const Duration(seconds: 1));
        final ip = await fetchVirtualIp(networkId);
        if (ip != null && ip.isNotEmpty) {
          assignedVirtualIp.value = ip;
          isConnecting.value = false;
          debugPrint('[ZeroTier] Virtual IP assigned: $ip for network $networkId');
          return true;
        }
      }
    } catch (e) {
      debugPrint('[ZeroTier] Join error: $e');
    }

    isConnecting.value = false;
    return false;
  }

  /// 할당받은 가상 IP(10.147.x.x 등) 조회
  Future<String?> fetchVirtualIp(String networkId) async {
    // 1. REST API로 조회
    if (_useApi && _apiToken != null) {
      try {
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
        final req = await client.getUrl(Uri.parse('http://127.0.0.1:$_apiPort/network/$networkId'));
        req.headers.set('X-ZT1-Auth', _apiToken!);
        final resp = await req.close();
        if (resp.statusCode == 200) {
          final body = await resp.transform(utf8.decoder).join();
          final data = jsonDecode(body) as Map<String, dynamic>;
          final addrs = data['assignedAddresses'] as List<dynamic>?;
          if (addrs != null && addrs.isNotEmpty) {
            for (final addr in addrs) {
              final str = addr.toString();
              final ip = str.split('/').first.trim();
              if (ip.split('.').length == 4) {
                client.close();
                return ip;
              }
            }
          }
        }
        client.close();
      } catch (e) {
        debugPrint('[ZeroTier] API fetchVirtualIp error: $e');
      }
    }

    // 2. CLI로 조회
    if (_cliPath != null) {
      try {
        final listRes = await Process.run(_cliPath!, ['listnetworks']);
        final out = listRes.stdout.toString();
        for (final line in out.split('\n')) {
          if (line.contains(networkId)) {
            final parts = line.trim().split(RegExp(r'\s+'));
            for (final part in parts) {
              if (part.contains('/')) {
                final cleanIp = part.split('/').first.trim();
                if (cleanIp.split('.').length == 4) {
                  return cleanIp;
                }
              }
            }
          }
        }
      } catch (e) {
        debugPrint('[ZeroTier] CLI listnetworks error: $e');
      }
    }

    // 3. 폴백: 시스템 네트워크 인터페이스 목록에서 10.147. 대역 검색
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.address.startsWith('10.147.') || iface.name.toLowerCase().contains('zt')) {
            return addr.address;
          }
        }
      }
    } catch (_) {}

    return null;
  }

  /// 합주 종료 시 가상 네트워크에서 즉시 탈퇴 (Leave)하여 가상 회선 소멸
  Future<bool> leaveNetwork(String? networkId) async {
    final targetId = networkId ?? currentNetworkId.value;
    if (targetId == null || targetId.isEmpty) return true;

    try {
      debugPrint('[ZeroTier] Leaving network: $targetId...');

      if (_useApi && _apiToken != null) {
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
        final req = await client.deleteUrl(Uri.parse('http://127.0.0.1:$_apiPort/network/$targetId'));
        req.headers.set('X-ZT1-Auth', _apiToken!);
        final resp = await req.close();
        client.close();
        debugPrint('[ZeroTier] API Leave response status: ${resp.statusCode}');
      } else if (_cliPath != null) {
        await Process.run(_cliPath!, ['leave', targetId]);
        debugPrint('[ZeroTier] CLI Successfully left network: $targetId');
      }
    } catch (e) {
      debugPrint('[ZeroTier] Leave error: $e');
    }

    currentNetworkId.value = null;
    assignedVirtualIp.value = null;
    isConnecting.value = false;
    return true;
  }
}

