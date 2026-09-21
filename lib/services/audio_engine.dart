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

typedef IsRunningNative = ffi.Int32 Function();
typedef IsRunningDart = int Function();

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
  IsRunningDart? _isRunning;

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

  double _currentRtt = 4.2; // ms (초기값 서울-경기 평균 핑)
  double get currentRtt => _currentRtt;

  double _inputLevel = 0.0;
  double get inputLevel => _inputLevel;

  double _outputLevel = 0.0;
  double get outputLevel => _outputLevel;

  Timer? _statsTimer;

  bool get isNativeRunning => (_isRunning?.call() ?? 0) != 0;

  AudioEngine._internal() {
    _tryLoadNativeLibrary();
  }

  void _tryLoadNativeLibrary() {
    try {
      if (Platform.isMacOS) {
        final candidates = [
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
    _statsTimer = Timer.periodic(const Duration(milliseconds: 80), (_) {
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
        _inputLevel = inLevelPtr.value;
        _outputLevel = outLevelPtr.value;

        calloc.free(rttPtr);
        calloc.free(inLevelPtr);
        calloc.free(outLevelPtr);
      } else {
        // 시뮬레이션 모드 (네이티브 미로딩 시 UI 레벨 미터 활성화)
        _inputLevel = (_inputLevel + 0.12) % 0.8;
        _outputLevel = (_outputLevel + 0.08) % 0.7;
      }
      notifyListeners();
    });
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}