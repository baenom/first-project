import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

// C++ Native 함수 시그니처 정의
typedef InitEngineNative = ffi.Int32 Function(ffi.Int32, ffi.Int32);
typedef InitEngineDart = int Function(int, int);

typedef SetSfuEndpointNative = ffi.Void Function(
    ffi.Pointer<Utf8>, ffi.Int32, ffi.Int32, ffi.Int32);
typedef SetSfuEndpointDart = void Function(
    ffi.Pointer<Utf8>, int, int, int);

typedef ControlStreamNative = ffi.Void Function();
typedef ControlStreamDart = void Function();

typedef SetVolumeNative = ffi.Void Function(ffi.Int32, ffi.Float);
typedef SetVolumeDart = void Function(int, double);

typedef SetGainNative = ffi.Void Function(ffi.Float);
typedef SetGainDart = void Function(double);

typedef GetStatsNative = ffi.Void Function(
    ffi.Pointer<ffi.Float>, ffi.Pointer<ffi.Float>, ffi.Pointer<ffi.Float>);
typedef GetStatsDart = void Function(
    ffi.Pointer<ffi.Float>, ffi.Pointer<ffi.Float>, ffi.Pointer<ffi.Float>);

typedef GetNetworkStatsNative = ffi.Void Function(
    ffi.Pointer<ffi.Uint32>, ffi.Pointer<ffi.Uint32>, ffi.Pointer<ffi.Int32>);
typedef GetNetworkStatsDart = void Function(
    ffi.Pointer<ffi.Uint32>, ffi.Pointer<ffi.Uint32>, ffi.Pointer<ffi.Int32>);

typedef IsRunningNative = ffi.Int32 Function();
typedef IsRunningDart = int Function();

typedef StartEmbeddedSfuNative = ffi.Int32 Function(ffi.Int32);
typedef StartEmbeddedSfuDart = int Function(int);

typedef StopEmbeddedSfuNative = ffi.Void Function();
typedef StopEmbeddedSfuDart = void Function();

typedef IsSfuRunningNative = ffi.Int32 Function();
typedef IsSfuRunningDart = int Function();

typedef GetSfuPeerCountNative = ffi.Int32 Function();
typedef GetSfuPeerCountDart = int Function();

class AudioStats {
  final double rttMs;
  final double inputLevel;
  final double outputLevel;

  const AudioStats({
    required this.rttMs,
    required this.inputLevel,
    required this.outputLevel,
  });
}

class AudioEngine extends ChangeNotifier {
  static final AudioEngine _instance = AudioEngine._internal();
  factory AudioEngine() => _instance;

  ffi.DynamicLibrary? _dylib;
  bool _isNativeLoaded = false;
  bool get isNativeLoaded => _isNativeLoaded;

  // 바인딩 함수들
  InitEngineDart? _initEngine;
  SetSfuEndpointDart? _setSfuEndpoint;
  ControlStreamDart? _startStream;
  ControlStreamDart? _stopStream;
  SetVolumeDart? _setChannelVolume;
  SetGainDart? _setInputGain;
  GetStatsDart? _getAudioStats;
  GetNetworkStatsDart? _getNetworkStats;
  IsRunningDart? _isRunning;

  // 내장 SFU 서버 바인딩
  StartEmbeddedSfuDart? _startEmbeddedSfu;
  StopEmbeddedSfuDart? _stopEmbeddedSfu;
  IsSfuRunningDart? _isSfuRunning;
  GetSfuPeerCountDart? _getSfuPeerCount;

  // 로컬 SFU 호스트 상태
  bool _isSfuServerRunning = false;
  bool get isSfuServerRunning => _isSfuServerRunning;
  int _sfuServerPort = 9999;
  int get sfuServerPort => _sfuServerPort;
  int _sfuServerPeerCount = 0;
  int get sfuServerPeerCount => _sfuServerPeerCount;
  Process? _fallbackSfuProcess;
  Timer? _sfuMonitorTimer;

  // 엔진 상태
  bool _isStreaming = false;
  bool get isStreaming => _isStreaming;

  int _sampleRate = 48000;
  int get sampleRate => _sampleRate;

  int _bufferSize = 128; // 64, 128, 256
  int get bufferSize => _bufferSize;

  String _sfuIp = '127.0.0.1';
  String get sfuIp => _sfuIp;

  int _sfuPort = 9999;
  int get sfuPort => _sfuPort;

  int _roomId = 1;
  int get roomId => _roomId;

  int _userId = 101;
  int get userId => _userId;

  void assignUniqueUserId([String? seed]) {
    if (seed != null && seed.isNotEmpty) {
      _userId = (seed.hashCode.abs() % 65000) + 100;
    } else {
      _userId = (DateTime.now().millisecondsSinceEpoch % 65000) + 100;
    }
  }

  // 네트워크 진단 지표
  int _txPackets = 0;
  int get txPackets => _txPackets;

  int _rxPackets = 0;
  int get rxPackets => _rxPackets;

  int _remotePeersCount = 0;
  int get remotePeersCount => _remotePeersCount;

  double _currentRtt = 4.2; // ms (초기값 서울-경기 평균 핑)
  double get currentRtt => _currentRtt;

  double _inputLevel = 0.0;
  double get inputLevel => _inputLevel;

  double _outputLevel = 0.0;
  double get outputLevel => _outputLevel;

  Timer? _statsTimer;

  bool get isNativeRunning => (_isRunning?.call() ?? 0) != 0;

  AudioEngine._internal() {
    assignUniqueUserId();
    _tryLoadNativeLibrary();
  }

  void _tryLoadNativeLibrary() {
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      if (Platform.isMacOS) {
        final candidates = [
          '$exeDir/libaudio_core.dylib',
          '$exeDir/../Frameworks/libaudio_core.dylib',
          'src/build/libaudio_core.dylib',
          'libaudio_core.dylib',
          '${Directory.current.path}/src/build/libaudio_core.dylib',
          '${Directory.current.path}/libaudio_core.dylib',
        ];
        for (final path in candidates) {
          if (File(path).existsSync()) {
            _dylib = ffi.DynamicLibrary.open(path);
            break;
          }
        }
        _dylib ??= ffi.DynamicLibrary.open('libaudio_core.dylib');
      } else if (Platform.isWindows) {
        final candidates = [
          '$exeDir/audio_core.dll',
          'src/build/Release/audio_core.dll',
          'src/build/audio_core.dll',
          'audio_core.dll',
        ];
        for (final path in candidates) {
          if (File(path).existsSync()) {
            _dylib = ffi.DynamicLibrary.open(path);
            break;
          }
        }
        _dylib ??= ffi.DynamicLibrary.open('audio_core.dll');
      }

      if (_dylib != null) {
        _initEngine = _dylib!
            .lookup<ffi.NativeFunction<InitEngineNative>>('init_audio_engine')
            .asFunction<InitEngineDart>();
        _setSfuEndpoint = _dylib!
            .lookup<ffi.NativeFunction<SetSfuEndpointNative>>('set_sfu_endpoint')
            .asFunction<SetSfuEndpointDart>();
        _startStream = _dylib!
            .lookup<ffi.NativeFunction<ControlStreamNative>>('start_audio_stream')
            .asFunction<ControlStreamDart>();
        _stopStream = _dylib!
            .lookup<ffi.NativeFunction<ControlStreamNative>>('stop_audio_stream')
            .asFunction<ControlStreamDart>();
        _setChannelVolume = _dylib!
            .lookup<ffi.NativeFunction<SetVolumeNative>>('set_channel_volume')
            .asFunction<SetVolumeDart>();
        _setInputGain = _dylib!
            .lookup<ffi.NativeFunction<SetGainNative>>('set_input_gain')
            .asFunction<SetGainDart>();
        _getAudioStats = _dylib!
            .lookup<ffi.NativeFunction<GetStatsNative>>('get_audio_stats')
            .asFunction<GetStatsDart>();
        _isRunning = _dylib!
            .lookup<ffi.NativeFunction<IsRunningNative>>('is_audio_running')
            .asFunction<IsRunningDart>();

        try {
          _startEmbeddedSfu = _dylib!
              .lookup<ffi.NativeFunction<StartEmbeddedSfuNative>>('start_embedded_sfu')
              .asFunction<StartEmbeddedSfuDart>();
          _stopEmbeddedSfu = _dylib!
              .lookup<ffi.NativeFunction<StopEmbeddedSfuNative>>('stop_embedded_sfu')
              .asFunction<StopEmbeddedSfuDart>();
          _isSfuRunning = _dylib!
              .lookup<ffi.NativeFunction<IsSfuRunningNative>>('is_sfu_running')
              .asFunction<IsSfuRunningDart>();
          _getSfuPeerCount = _dylib!
              .lookup<ffi.NativeFunction<GetSfuPeerCountNative>>('get_sfu_peer_count')
              .asFunction<GetSfuPeerCountDart>();
        } catch (e) {
          debugPrint("[AudioEngine] Embedded SFU symbols optional lookup note: $e");
        }

        try {
          _getNetworkStats = _dylib!
              .lookup<ffi.NativeFunction<GetNetworkStatsNative>>('get_network_stats')
              .asFunction<GetNetworkStatsDart>();
        } catch (e) {
          debugPrint("[AudioEngine] Network stats optional lookup note: $e");
        }

        _isNativeLoaded = true;
        debugPrint("[AudioEngine] Native C++ audio core successfully linked.");
      }
    } catch (e) {
      debugPrint("[AudioEngine] Native library load fallback mode: $e");
      _isNativeLoaded = false;
    }
  }

  void initialize(int sampleRate, int bufferSize) {
    _sampleRate = sampleRate;
    _bufferSize = bufferSize;

    if (_isNativeLoaded && _initEngine != null) {
      _initEngine!(sampleRate, bufferSize);
    }
    configureSfu(_sfuIp, _sfuPort, _roomId, _userId);
    notifyListeners();
  }

  void configureSfu(String ip, int port, int roomId, int userId) {
    _sfuIp = ip;
    _sfuPort = port;
    _roomId = roomId;
    _userId = userId;

    if (_isNativeLoaded && _setSfuEndpoint != null) {
      final ipPtr = ip.toNativeUtf8();
      _setSfuEndpoint!(ipPtr, port, roomId, userId);
      calloc.free(ipPtr);
    }
    notifyListeners();
  }

  /// 방장 모드: 내장 C++ SFU 서버 시작 (실패 시 sfu_server 바이너리 폴백)
  bool startHostSfu({int port = 9999}) {
    _sfuServerPort = port;
    bool started = false;

    if (_isNativeLoaded && _startEmbeddedSfu != null) {
      final res = _startEmbeddedSfu!(port);
      if (res == 0) {
        _isSfuServerRunning = true;
        started = true;
        debugPrint("[AudioEngine] Embedded SFU Server started on port $port");
      }
    }

    if (!started && _fallbackSfuProcess == null) {
      // 별도 빌드된 sfu_server 바이너리 폴백
      final candidates = [
        'SFU/build/sfu_server',
        '${Directory.current.path}/SFU/build/sfu_server',
      ];
      for (final path in candidates) {
        if (File(path).existsSync()) {
          try {
            Process.start(path, [port.toString()]).then((proc) {
              _fallbackSfuProcess = proc;
              _isSfuServerRunning = true;
              debugPrint("[AudioEngine] Standalone SFU process started on port $port (PID: ${proc.pid})");
              notifyListeners();
            });
            started = true;
            break;
          } catch (e) {
            debugPrint("[AudioEngine] Process fallback failed: $e");
          }
        }
      }
    }

    if (started) {
      _isSfuServerRunning = true;
      // 방장 본인은 0ms 초저지연 루프백(127.0.0.1)으로 즉시 연결
      configureSfu('127.0.0.1', port, _roomId, _userId);
      _startSfuMonitoring();
    } else {
      // 네이티브/바이너리 모두 없는 환경에서도 UI 시뮬레이션 동작
      _isSfuServerRunning = true;
      configureSfu('127.0.0.1', port, _roomId, _userId);
    }

    notifyListeners();
    return _isSfuServerRunning;
  }

  /// 방장 모드: 내장 SFU 서버 정지
  void stopHostSfu() {
    _sfuMonitorTimer?.cancel();
    _sfuMonitorTimer = null;

    if (_isNativeLoaded && _stopEmbeddedSfu != null) {
      _stopEmbeddedSfu!();
    }
    if (_fallbackSfuProcess != null) {
      _fallbackSfuProcess?.kill();
      _fallbackSfuProcess = null;
    }

    _isSfuServerRunning = false;
    _sfuServerPeerCount = 0;
    debugPrint("[AudioEngine] SFU Server stopped.");
    notifyListeners();
  }

  void _startSfuMonitoring() {
    _sfuMonitorTimer?.cancel();
    _sfuMonitorTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_isSfuServerRunning) return;

      if (_isNativeLoaded && _getSfuPeerCount != null) {
        final count = _getSfuPeerCount!();
        if (count != _sfuServerPeerCount) {
          _sfuServerPeerCount = count;
          notifyListeners();
        }
      }
    });
  }

  /// Tailscale 가상 사설망 IP 및 로컬 공유기 IP 자동 감지
  Future<Map<String, String>> detectHostIps() async {
    String? tailscaleIp;
    String? lanIp;

    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );

      for (final iface in interfaces) {
        final ifaceName = iface.name.toLowerCase();
        for (final addr in iface.addresses) {
          final ip = addr.address;
          // Tailscale 주소 대역 (100.64.0.0/10) 또는 utun/tailscale 인터페이스
          if (ip.startsWith('100.') || ifaceName.contains('tailscale') || ifaceName.contains('utun')) {
            tailscaleIp ??= ip;
          } else if (!ip.startsWith('127.') && !ip.startsWith('169.254.')) {
            // 사설 LAN 대역 (192.168.x.x, 10.x.x.x, 172.16-31.x.x)
            lanIp ??= ip;
          }
        }
      }
    } catch (e) {
      debugPrint("[AudioEngine] Error detecting local IPs: $e");
    }

    return {
      'tailscale': tailscaleIp ?? '',
      'lan': lanIp ?? '',
      'loopback': '127.0.0.1',
    };
  }

  void setBufferSize(int newSize) {
    _bufferSize = newSize;
    if (_isNativeLoaded && _initEngine != null) {
      _initEngine!(_sampleRate, newSize);
    }
    notifyListeners();
  }

  void start() {
    _isStreaming = true;
    if (_isNativeLoaded && _startStream != null) {
      _startStream!();
    }

    _startStatsPolling();
    notifyListeners();
  }

  void stop() {
    _isStreaming = false;
    if (_isNativeLoaded && _stopStream != null) {
      _stopStream!();
    }

    _statsTimer?.cancel();
    _inputLevel = 0.0;
    _outputLevel = 0.0;
    notifyListeners();
  }

  void setChannelVolume(int peerUserId, double volume) {
    if (_isNativeLoaded && _setChannelVolume != null) {
      _setChannelVolume!(peerUserId, volume);
    }
  }

  void setInputGain(double gain) {
    if (_isNativeLoaded && _setInputGain != null) {
      _setInputGain!(gain);
    }
  }

  void _startStatsPolling() {
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(milliseconds: 60), (_) {
      if (!_isStreaming) return;

      if (_isNativeLoaded && _getAudioStats != null) {
        final rttPtr = calloc<ffi.Float>();
        final inLevelPtr = calloc<ffi.Float>();
        final outLevelPtr = calloc<ffi.Float>();

        _getAudioStats!(rttPtr, inLevelPtr, outLevelPtr);

        final rtt = rttPtr.value;
        if (rtt > 0.01) {
          _currentRtt = rtt;
        }
        _inputLevel = inLevelPtr.value.clamp(0.0, 1.0);
        _outputLevel = outLevelPtr.value.clamp(0.0, 1.0);

        calloc.free(rttPtr);
        calloc.free(inLevelPtr);
        calloc.free(outLevelPtr);

        if (_getNetworkStats != null) {
          final txPtr = calloc<ffi.Uint32>();
          final rxPtr = calloc<ffi.Uint32>();
          final peersPtr = calloc<ffi.Int32>();

          _getNetworkStats!(txPtr, rxPtr, peersPtr);
          _txPackets = txPtr.value;
          _rxPackets = rxPtr.value;
          _remotePeersCount = peersPtr.value;

          calloc.free(txPtr);
          calloc.free(rxPtr);
          calloc.free(peersPtr);
        }
      } else {
        // 실제 마이크 미연동 시 0 레벨 유지 (가짜 널뛰기 방지)
        _inputLevel = 0.0;
        _outputLevel = 0.0;
      }
      notifyListeners();
    });
  }

  @override
  void dispose() {
    stop();
    stopHostSfu();
    super.dispose();
  }
}