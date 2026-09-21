import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gam/main.dart';
import 'package:gam/screens/main_lobby_screen.dart';
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

  tearDown(() {
    final engine = AudioEngine();
    engine.stop();
    engine.stopHostSfu();
  });

  test('AudioEngine initialization, configuration and host SFU test', () async {
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

    // Test Host SFU Server start
    final started = engine.startHostSfu(port: 9999);
    expect(started, isTrue);
    expect(engine.isSfuServerRunning, isTrue);
    expect(engine.sfuIp, '127.0.0.1');

    // Test IP detection
    final ips = await engine.detectHostIps();
    expect(ips, contains('loopback'));
    expect(ips['loopback'], '127.0.0.1');

    // Stop Host SFU
    engine.stopHostSfu();
    expect(engine.isSfuServerRunning, isFalse);
  });

  testWidgets('MainLobbyScreen opens create room dialog and adds room', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    await tester.pumpWidget(const MaterialApp(home: MainLobbyScreen()));
    await tester.pump();

    // Verify initial state
    expect(find.text('우리들만의 합주실'), findsWidgets);

    // Find the "+" button for '새 합주실 개설'
    final addBtn = find.byTooltip('새 합주실 개설');
    expect(addBtn, findsOneWidget);

    // Tap the "+" button
    await tester.tap(addBtn);
    await tester.pumpAndSettle();

    // Verify dialog opened
    expect(find.text('새 합주실 개설'), findsWidgets);
    expect(find.text('합주실 기본 정보'), findsOneWidget);
    expect(find.text('합주실 개설'), findsOneWidget);

    // Tap create button
    await tester.tap(find.widgetWithText(ElevatedButton, '합주실 개설'));
    await tester.pumpAndSettle();

    // Verify dialog is closed and new room is created
    expect(find.text('새 합주실 #2'), findsWidgets);
  });

  testWidgets('MainLobbyScreen logout button shows confirmation dialog', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    await tester.pumpWidget(const MaterialApp(home: MainLobbyScreen()));
    await tester.pump();

    // Find the logout button in profile bar
    final logoutBtn = find.byTooltip('로그아웃');
    expect(logoutBtn, findsOneWidget);

    // Tap logout button
    await tester.tap(logoutBtn);
    await tester.pumpAndSettle();

    // Verify confirmation dialog
    expect(find.text('정말 합주실에서 로그아웃하시겠습니까?\n저장된 로그인 세션이 해제됩니다.'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '취소'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, '로그아웃'), findsOneWidget);

    // Cancel dialog
    await tester.tap(find.widgetWithText(TextButton, '취소'));
    await tester.pumpAndSettle();

    expect(find.text('정말 합주실에서 로그아웃하시겠습니까?\n저장된 로그인 세션이 해제됩니다.'), findsNothing);
  });
}

