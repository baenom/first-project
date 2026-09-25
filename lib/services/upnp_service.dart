import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:upnp_client/upnp_client.dart';

class UpnpService {
  static final UpnpService _instance = UpnpService._internal();
  factory UpnpService() => _instance;
  UpnpService._internal();

  /// Flag to enable fast mock responses in widget tests to prevent pumpAndSettle timeout
  static bool mockInTests = false;

  bool _isPortMapped = false;
  int _mappedPort = 9999;
  String _publicIp = '';
  String _localLanIp = '';
  String _statusMessage = 'UPnP 대기중';
  WanConnectionService? _activeConnection;

  bool get isPortMapped => _isPortMapped;
  int get mappedPort => _mappedPort;
  String get publicIp => _publicIp;
  String get localLanIp => _localLanIp;
  String get statusMessage => _statusMessage;

  /// Detects the local LAN IP (e.g. 192.168.x.x, 10.x.x.x, excluding 100.x Tailscale & loopback)
  Future<String> detectLocalLanIp() async {
    if (mockInTests) {
      _localLanIp = '192.168.1.100';
      return _localLanIp;
    }
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );

      // Prioritize Wi-Fi and Ethernet (en0, en1, eth0, wlan0)
      for (final iface in interfaces) {
        final name = iface.name.toLowerCase();
        if (name.startsWith('utun') || name.startsWith('tailscale')) continue;
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (ip.startsWith('192.168.') ||
              ip.startsWith('10.') ||
              (ip.startsWith('172.') && !ip.startsWith('100.'))) {
            _localLanIp = ip;
            return ip;
          }
        }
      }

      // Fallback to any non-loopback IPv4
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback && !addr.address.startsWith('100.')) {
            _localLanIp = addr.address;
            return addr.address;
          }
        }
      }
    } catch (e) {
      debugPrint('[UpnpService] Error detecting local LAN IP: $e');
    }
    return '127.0.0.1';
  }

  /// Fetches the external public IP using public IP APIs (fallback if UPnP doesn't report it)
  Future<String> fetchPublicIpFromWeb() async {
    if (mockInTests) {
      _publicIp = '112.76.111.30';
      return _publicIp;
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    final endpoints = [
      'https://api.ipify.org',
      'https://icanhazip.com',
      'https://ifconfig.me/ip',
    ];

    for (final url in endpoints) {
      try {
        final req = await client.getUrl(Uri.parse(url));
        final resp = await req.close();
        if (resp.statusCode == 200) {
          final body = (await resp.transform(utf8.decoder).join()).trim();
          if (body.isNotEmpty && InternetAddress.tryParse(body) != null) {
            _publicIp = body;
            return body;
          }
        }
      } catch (_) {}
    }
    return _publicIp;
  }

  /// Automatically discovers the router using UPnP IGD and maps the UDP port
  Future<bool> openPort({
    int port = 9999,
    PortMappingProtocol protocol = PortMappingProtocol.udp,
    String description = 'GAM Jam SFU UDP',
  }) async {
    _mappedPort = port;
    if (mockInTests) {
      _localLanIp = '192.168.1.100';
      _publicIp = '112.76.111.30';
      _isPortMapped = true;
      _statusMessage = 'UPnP 포트 포워딩 성공 (공유기 UDP $port 개방 완료)';
      return true;
    }
    final localIp = await detectLocalLanIp();
    _statusMessage = '공유기 UPnP 검색 중...';
    debugPrint('[UpnpService] Starting UPnP discovery for $localIp:$port ($protocol)...');

    // 1. Fetch public IP in background as fast fallback
    fetchPublicIpFromWeb();

    DeviceDiscoverer? discoverer;
    try {
      discoverer = DeviceDiscoverer();
      await discoverer.start(addressTypes: [InternetAddressType.IPv4]);

      final devices = await discoverer.getDevices(
        timeout: const Duration(seconds: 3),
      );

      debugPrint('[UpnpService] Found ${devices.length} UPnP devices');

      for (final device in devices) {
        try {
          final connection = device.findService<WanConnectionService>();
          if (connection != null) {
            _activeConnection = connection;

            // Try to get external IP from router
            try {
              final extIp = await connection.getExternalIpAddress();
              if (extIp != null && extIp.isNotEmpty && extIp != '0.0.0.0') {
                _publicIp = extIp;
                debugPrint('[UpnpService] Router reported WAN IP: $_publicIp');
              }
            } catch (e) {
              debugPrint('[UpnpService] getExternalIpAddress notice: $e');
            }

            // Execute AddPortMapping on router
            await connection.addPortMapping(
              externalPort: port,
              protocol: protocol,
              internalPort: port,
              internalClient: localIp,
              description: description,
              enabled: true,
              leaseDuration: Duration.zero, // Permanent until closed
            );

            _isPortMapped = true;
            _statusMessage = 'UPnP 포트 포워딩 성공 (공유기 UDP $port 개방 완료)';
            debugPrint('[UpnpService] Successfully mapped port $port via UPnP!');
            discoverer.stop();
            return true;
          }
        } catch (e) {
          debugPrint('[UpnpService] Device connection attempt notice: $e');
        }
      }
    } catch (e) {
      debugPrint('[UpnpService] UPnP Discovery error: $e');
    } finally {
      try {
        discoverer?.stop();
      } catch (_) {}
    }

    // If UPnP router didn't respond or failed, make sure we have the public IP
    if (_publicIp.isEmpty) {
      await fetchPublicIpFromWeb();
    }

    _isPortMapped = false;
    if (_publicIp.isNotEmpty) {
      _statusMessage = '공인 IP 확인됨 ($_publicIp) • 공유기 UPnP 미지원 시 포트 9999 수동 개방 필요';
    } else {
      _statusMessage = '공유기 UPnP 응답 없음 (로컬 LAN 또는 수동 포트포워딩 필요)';
    }

    debugPrint('[UpnpService] UPnP finished with status: $_statusMessage');
    return false;
  }

  /// Closes the UPnP port mapping when the SFU stops or room closes
  Future<void> closePort({
    int? port,
    PortMappingProtocol protocol = PortMappingProtocol.udp,
  }) async {
    if (mockInTests) {
      _isPortMapped = false;
      _statusMessage = 'UPnP 포트 닫힘';
      return;
    }
    final targetPort = port ?? _mappedPort;
    if (_activeConnection != null && _isPortMapped) {
      try {
        debugPrint('[UpnpService] Closing UPnP port mapping for $targetPort...');
        await _activeConnection!.deletePortMapping(
          externalPort: targetPort,
          protocol: protocol,
        );
        debugPrint('[UpnpService] Port $targetPort mapping removed.');
      } catch (e) {
        debugPrint('[UpnpService] deletePortMapping notice: $e');
      }
    }
    _isPortMapped = false;
    _statusMessage = 'UPnP 포트 닫힘';
  }
}
