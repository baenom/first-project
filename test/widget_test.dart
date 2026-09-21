import 'package:flutter_test/flutter_test.dart';
import 'package:gam/main.dart';
import 'package:gam/services/audio_engine.dart';

void main() {
  testWidgets('SyncRoomApp boots up with LoginScreen and no overflow', (WidgetTester tester) async {
    await tester.pumpWidget(const SyncRoomApp());
    await tester.pump();

    // 로그인 화면 요소 확인
    expect(find.text('합주실 입장'), findsOneWidget);
    expect(find.text('이메일'), findsOneWidget);
    expect(find.text('합주실 로비 접속'), findsOneWidget);
  });

  test('AudioEngine initialization and configuration test', () {
    final engine = AudioEngine();
    engine.initialize(48000, 128);

    expect(engine.sampleRate, 48000);
    expect(engine.bufferSize, 128);

    engine.configureSfu('192.168.0.50', 9999, 1, 101);
    expect(engine.sfuIp, '192.168.0.50');
    expect(engine.sfuPort, 9999);
    expect(engine.roomId, 1);
    expect(engine.userId, 101);

    engine.setBufferSize(64);
    expect(engine.bufferSize, 64);
  });
}
