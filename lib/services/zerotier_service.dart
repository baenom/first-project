import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

class ZeroTierService {
  static final ZeroTierService _instance = ZeroTierService._internal();
  factory ZeroTierService() => _instance;
  ZeroTierService._internal();

  String? _cliPath;
  bool _cliDetected = false;

  final ValueNotifier<String?> currentNetworkId = ValueNotifier<String?>(null);
  final ValueNotifier<String?> assignedVirtualIp = ValueNotifier<String?>(null);
  final ValueNotifier<bool> isConnecting = ValueNotifier<bool>(false);

  bool get isConnected => currentNetworkId.value != null && assignedVirtualIp.value != null;

  /// 로컬 컴퓨터에서 zerotier-cli 실행 파일 경로 감지
  Future<String?> findCliPath() async {
    if (_cliDetected) return _cliPath;
    _cliDetected = true;

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
              return _cliPath;
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
              return _cliPath;
            }
          } catch (_) {}
        }
      }
    }

    debugPrint('[ZeroTier] zerotier-cli not detected or service not running.');
    return null;
  }

  /// 1회용 가상 네트워크에 자동 참여 (Join)
  Future<bool> joinNetwork(String networkId) async {
    if (networkId.isEmpty) return false;
    isConnecting.value = true;
    currentNetworkId.value = networkId;

    final cli = await findCliPath();
    if (cli == null) {
      debugPrint('[ZeroTier] Cannot join: ZeroTier One is not running or not installed.');
      isConnecting.value = false;
      return false;
    }

    try {
      debugPrint('[ZeroTier] Joining network: $networkId...');
      final joinRes = await Process.run(cli, ['join', networkId]);
      debugPrint('[ZeroTier] Join response: ${joinRes.stdout}');

      // IP가 할당될 때까지 최대 12초간 대기 (1초 간격 폴링)
      for (int i = 0; i < 12; i++) {
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

  /// 할당받은 가상 IP(10.147.x.x) 조회
  Future<String?> fetchVirtualIp(String networkId) async {
    final cli = _cliPath;
    if (cli != null) {
      try {
        final listRes = await Process.run(cli, ['listnetworks']);
        final out = listRes.stdout.toString();
        // 포맷: 200 listnetworks <nwid> <name> <mac> <status> <type> <dev> <assigned_addresses>
        for (final line in out.split('\n')) {
          if (line.contains(networkId)) {
            final parts = line.trim().split(RegExp(r'\s+'));
            for (final part in parts) {
              if (part.contains('/')) {
                final cleanIp = part.split('/').first.trim();
                final segments = cleanIp.split('.');
                if (segments.length == 4) {
                  return cleanIp;
                }
              }
            }
          }
        }
      } catch (e) {
        debugPrint('[ZeroTier] listnetworks error: $e');
      }
    }

    // 폴백: 시스템 네트워크 인터페이스 목록에서 10.147. 대역 검색
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

    final cli = _cliPath;
    if (cli != null) {
      try {
        debugPrint('[ZeroTier] Leaving network: $targetId...');
        await Process.run(cli, ['leave', targetId]);
        debugPrint('[ZeroTier] Successfully left network: $targetId');
      } catch (e) {
        debugPrint('[ZeroTier] Leave error: $e');
      }
    }

    currentNetworkId.value = null;
    assignedVirtualIp.value = null;
    isConnecting.value = false;
    return true;
  }
}
