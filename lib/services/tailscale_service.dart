import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

class TailscaleService {
  static final TailscaleService _instance = TailscaleService._internal();
  factory TailscaleService() => _instance;
  TailscaleService._internal();

  String? _cliPath;
  bool _detected = false;

  final ValueNotifier<String?> assignedVirtualIp = ValueNotifier<String?>(null);
  final ValueNotifier<String?> derpRegion = ValueNotifier<String?>('서울 DERP-9 (sel)');
  final ValueNotifier<bool> isConnecting = ValueNotifier<bool>(false);
  final ValueNotifier<String?> currentAuthKey = ValueNotifier<String?>(null);

  bool get isConnected => assignedVirtualIp.value != null && assignedVirtualIp.value!.isNotEmpty;

  /// 로컬 컴퓨터에서 Tailscale CLI 경로 감지
  Future<bool> detectService() async {
    if (_detected && _cliPath != null) return true;
    _detected = true;

    // 1. 이미 네트워크 인터페이스에 100.x.x.x Tailscale IP가 할당되어 있는지 확인
    final detectedIp = await _detectLocalTailscaleInterface();
    if (detectedIp != null && detectedIp.isNotEmpty) {
      assignedVirtualIp.value = detectedIp;
      debugPrint('[Tailscale] Active 100.x.x.x interface found: $detectedIp');
    }

    // 2. CLI 탐색 (macOS 및 Windows)
    if (Platform.isMacOS) {
      final candidates = [
        '/Applications/Tailscale.app/Contents/MacOS/Tailscale',
        '/usr/local/bin/tailscale',
        '/opt/homebrew/bin/tailscale',
        'tailscale',
      ];
      for (final p in candidates) {
        if (p == 'tailscale' || File(p).existsSync()) {
          try {
            final res = await Process.run(p, ['version']);
            if (res.exitCode == 0) {
              _cliPath = p;
              debugPrint('[Tailscale] CLI found on macOS: $p');
              return true;
            }
          } catch (_) {}
        }
      }
    } else if (Platform.isWindows) {
      final candidates = [
        r'C:\Program Files\Tailscale\tailscale.exe',
        r'C:\Program Files (x86)\Tailscale\tailscale.exe',
        'tailscale',
      ];
      for (final p in candidates) {
        if (p == 'tailscale' || File(p).existsSync()) {
          try {
            final res = await Process.run(p, ['version']);
            if (res.exitCode == 0) {
              _cliPath = p;
              debugPrint('[Tailscale] CLI found on Windows: $p');
              return true;
            }
          } catch (_) {}
        }
      }
    }

    if (assignedVirtualIp.value != null) {
      return true; // CLI가 없더라도 GUI 앱으로 100.x.x.x가 켜져 있으면 성공
    }

    debugPrint('[Tailscale] CLI or active interface not detected.');
    return false;
  }

  /// OS 네트워크 인터페이스 목록에서 100.x.x.x Tailscale IP 탐색
  Future<String?> _detectLocalTailscaleInterface() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        final name = iface.name.toLowerCase();
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (ip.startsWith('100.') || name.contains('tailscale') || name.contains('utun')) {
            if (ip.startsWith('100.')) {
              return ip;
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[Tailscale] Error listing interfaces: $e');
    }
    return null;
  }

  /// Tailscale 가상 회선 접속 (1회용 Auth Key 적용)
  Future<bool> joinTailnet({String? authKey}) async {
    isConnecting.value = true;
    currentAuthKey.value = authKey;

    try {
      await detectService();

      // 1. Auth Key가 있고 CLI가 사용 가능한 경우 `tailscale up` 실행
      if (_cliPath != null && authKey != null && authKey.isNotEmpty) {
        debugPrint('[Tailscale] Executing: $_cliPath up --authkey=... --accept-routes');
        final args = ['up', '--auth-key=$authKey', '--accept-routes'];
        try {
          final res = await Process.run(_cliPath!, args).timeout(const Duration(seconds: 15));
          debugPrint('[Tailscale up exitCode: ${res.exitCode}, stdout: ${res.stdout}, stderr: ${res.stderr}]');
        } catch (e) {
          debugPrint('[Tailscale] up command timed out or failed: $e');
        }
      }

      // 2. 가상 IP 할당 대기 (최대 10초 폴링)
      for (int i = 0; i < 20; i++) {
        // CLI로 ip 조회 시도
        if (_cliPath != null) {
          try {
            final res = await Process.run(_cliPath!, ['ip', '-4']);
            final ip = res.stdout.toString().trim();
            if (res.exitCode == 0 && ip.startsWith('100.')) {
              assignedVirtualIp.value = ip;
              isConnecting.value = false;
              debugPrint('[Tailscale] Successfully assigned Virtual IP via CLI: $ip');
              _queryDerpStatus();
              return true;
            }
          } catch (_) {}
        }

        // 네트워크 인터페이스 조회 시도
        final ifaceIp = await _detectLocalTailscaleInterface();
        if (ifaceIp != null && ifaceIp.startsWith('100.')) {
          assignedVirtualIp.value = ifaceIp;
          isConnecting.value = false;
          debugPrint('[Tailscale] Successfully detected Virtual IP on interface: $ifaceIp');
          _queryDerpStatus();
          return true;
        }

        await Future.delayed(const Duration(milliseconds: 500));
      }
    } catch (e) {
      debugPrint('[Tailscale] Error joining tailnet: $e');
    }

    isConnecting.value = false;
    return assignedVirtualIp.value != null;
  }

  /// DERP 중계 상태 확인 (서울 릴레이 체크)
  Future<void> _queryDerpStatus() async {
    if (_cliPath == null) return;
    try {
      final res = await Process.run(_cliPath!, ['status', '--json']);
      if (res.exitCode == 0) {
        final data = jsonDecode(res.stdout.toString());
        // Self derp 확인
        final selfData = data['Self'];
        if (selfData != null && selfData['Relay'] != null) {
          final relay = selfData['Relay'].toString();
          if (relay.contains('sel') || relay.contains('seoul')) {
            derpRegion.value = '대한민국 서울 DERP-9 (sel) 초저지연 직결';
          } else {
            derpRegion.value = 'Tailscale Relay ($relay)';
          }
        }
      }
    } catch (_) {}
  }

  /// Tailscale 가상 회선 종료
  Future<void> leaveTailnet() async {
    currentAuthKey.value = null;
    isConnecting.value = false;
    // 백그라운드 데몬 자체를 끄진 않고 할당 상태만 해제
    assignedVirtualIp.value = null;
  }
}
