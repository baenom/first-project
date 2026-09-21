import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gam/main.dart';
import 'package:gam/screens/main_lobby_screen.dart';
import 'package:gam/screens/jam_room_screen.dart';
import 'package:gam/services/audio_engine.dart';
import 'package:gam/services/upnp_service.dart';

void main() {
  setUpAll(() {
    UpnpService.mockInTests = true;
  });

  tearDown(() {
    final engine = AudioEngine();
    engine.stop();
    engine.stopHostSfu();
    UpnpService().closePort();
  });

  testWidgets('SyncRoomApp boots up with LoginScreen and no overflow', (WidgetTester tester) async {
    await tester.pumpWidget(const SyncRoomApp());
    await tester.pump();

    // 로그인 화면 요소 확인
    expect(find.text('합주실 입장'), findsOneWidget);
    expect(find.text('이메일'), findsOneWidget);
    expect(find.text('합주실 로비 접속'), findsOneWidget);
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

  testWidgets('LoginScreen toggles to sign up mode and displays nickname input field', (WidgetTester tester) async {
    await tester.pumpWidget(const SyncRoomApp());
    await tester.pump();

    // In login mode, nickname field is not present
    expect(find.text('합주실 닉네임 (활동명)'), findsNothing);

    // Tap toggle to sign up mode ("새 멤버 등록이 필요하신가요? 회원가입")
    final toggleBtn = find.text('새 멤버 등록이 필요하신가요? 회원가입');
    expect(toggleBtn, findsOneWidget);
    await tester.tap(toggleBtn);
    await tester.pump();

    // In sign up mode, nickname field is visible
    expect(find.text('합주 멤버 가입'), findsOneWidget);
    expect(find.text('합주실 닉네임 (활동명)'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, '계정 생성 후 입장'), findsOneWidget);
  });

  testWidgets('MainLobbyScreen clicking profile opens edit nickname dialog', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    await tester.pumpWidget(const MaterialApp(home: MainLobbyScreen()));
    await tester.pump();

    // Click profile area with tooltip
    final profileTooltip = find.byTooltip('클릭하여 닉네임(활동명) 변경');
    expect(profileTooltip, findsOneWidget);

    await tester.tap(profileTooltip);
    await tester.pumpAndSettle();

    // Verify nickname dialog opened
    expect(find.text('닉네임(활동명) 변경'), findsOneWidget);
    expect(find.text('새 닉네임'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, '변경 저장'), findsOneWidget);

    // Cancel dialog
    await tester.tap(find.widgetWithText(TextButton, '취소'));
    await tester.pumpAndSettle();
    expect(find.text('닉네임(활동명) 변경'), findsNothing);
  });

  testWidgets('JamRoomScreen shows host card and toggle when isHost is true', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());
    addTearDown(() => AudioEngine().stopHostSfu());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: JamRoomScreen(
            roomName: '테스트 합주실',
            roomId: 10,
            isHost: true,
            isJamming: false,
            onToggleJam: () {},
            onOpenSettings: () {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('내가 이 방의 SFU 호스트 (방장)'), findsOneWidget);
    expect(find.text('공인 IP (친구 전달용 - UPnP 자동 개방)'), findsOneWidget);
    // Button to toggle server is present
    expect(find.text('서버 중지'), findsWidgets);

    AudioEngine().stopHostSfu();
    await tester.pump();
  });

  testWidgets('JamRoomScreen shows guest card when isHost is false', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: JamRoomScreen(
            roomName: '친구의 합주실',
            roomId: 20,
            isHost: false,
            hostName: '김철수',
            hostPublicIp: '112.76.111.30',
            hostTailscaleIp: '100.10.20.30',
            hostLanIp: '192.168.0.2',
            port: 9999,
            isJamming: false,
            onToggleJam: () {},
            onOpenSettings: () {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('게스트 접속 모드 (방장: 김철수)'), findsOneWidget);
    expect(find.text('방장의 공인 IP (UPnP 공유기 직결)'), findsOneWidget);
    expect(find.text('내가 이 방의 SFU 호스트 (방장)'), findsNothing);
    expect(find.text('SFU 서버 정지됨'), findsNothing);
  });

  testWidgets('MainLobbyScreen long press on room card triggers delete dialog', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    await tester.pumpWidget(const MaterialApp(home: MainLobbyScreen()));
    await tester.pump();

    // Navigate to session hub
    await tester.tap(find.byTooltip('합주 세션 로비 (전체 목록)'));
    await tester.pumpAndSettle();

    // Find the room card in the session hub
    final roomCard = find.text('우리들만의 합주실').first;
    expect(roomCard, findsOneWidget);

    // Long press on the room card
    await tester.longPress(roomCard);
    await tester.pumpAndSettle();

    // Verify delete confirmation dialog appears
    expect(find.text('합주실 삭제'), findsOneWidget);
    expect(find.text('\'우리들만의 합주실\' 합주실을 삭제하시겠습니까?'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '취소'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, '삭제'), findsOneWidget);

    // Tap cancel
    await tester.tap(find.widgetWithText(TextButton, '취소'));
    await tester.pumpAndSettle();

    expect(find.text('합주실 삭제'), findsNothing);
  });
}


