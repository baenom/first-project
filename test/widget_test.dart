import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gam/main.dart';
import 'package:gam/screens/main_lobby_screen.dart';
import 'package:gam/screens/jam_room_screen.dart';
import 'package:gam/services/audio_engine.dart';
import 'package:gam/services/upnp_service.dart';
import 'package:gam/services/deep_link_service.dart';

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

  testWidgets('SyncRoomApp boots up with LoginScreen and no overflow', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const SyncRoomApp());
    await tester.pump();

    // 로그인 화면 요소 확인
    expect(find.text('합주실 입장'), findsOneWidget);
    expect(find.text('이메일 또는 닉네임'), findsOneWidget);
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

  testWidgets('MainLobbyScreen opens create room dialog and adds room', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    await tester.pumpWidget(const MaterialApp(home: MainLobbyScreen()));
    await tester.pump();

    // Verify initial state
    expect(find.text('합주실'), findsWidgets);

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

  testWidgets('MainLobbyScreen logout button shows confirmation dialog', (
    WidgetTester tester,
  ) async {
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
    expect(
      find.text('정말 합주실에서 로그아웃하시겠습니까?\n저장된 로그인 세션이 해제됩니다.'),
      findsOneWidget,
    );
    expect(find.widgetWithText(TextButton, '취소'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, '로그아웃'), findsOneWidget);

    // Cancel dialog
    await tester.tap(find.widgetWithText(TextButton, '취소'));
    await tester.pumpAndSettle();

    expect(find.text('정말 합주실에서 로그아웃하시겠습니까?\n저장된 로그인 세션이 해제됩니다.'), findsNothing);
  });

  testWidgets(
    'LoginScreen toggles to sign up mode and displays nickname input field',
    (WidgetTester tester) async {
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
    },
  );

  testWidgets('MainLobbyScreen clicking profile opens edit nickname dialog', (
    WidgetTester tester,
  ) async {
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

  testWidgets('JamRoomScreen shows host card and toggle when isHost is true', (
    WidgetTester tester,
  ) async {
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

  testWidgets('JamRoomScreen shows guest card when isHost is false', (
    WidgetTester tester,
  ) async {
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

    // 내가 방장으로 서버 켜기 버튼 클릭 시 즉시 방장 모드로 전환되는지 검증
    final hostSwitchBtn = find.text('내가 방장으로 서버 켜기');
    expect(hostSwitchBtn, findsOneWidget);
    await tester.tap(hostSwitchBtn);
    await tester.pump();

    expect(find.text('내가 이 방의 SFU 호스트 (방장)'), findsOneWidget);
    expect(find.text('게스트 접속 모드 (방장: 김철수)'), findsNothing);
    AudioEngine().stopHostSfu();
  });

  test('DeepLinkService correctly parses gam:// URL with parameters', () {
    final service = DeepLinkService();

    // 1. 방장 모드 URL 파싱 테스트
    const hostUrl =
        'gam://jam?user=%ED%99%8D%EA%B8%B8%EB%8F%99&uid=discord_99999&roomId=7&name=%EC%9E%AC%EC%A6%88%ED%95%A9%EC%A3%BC&isHost=true&port=9999&ip=61.102.205.131';
    final hostData = service.parseUrl(hostUrl);
    expect(hostData, isNotNull);
    expect(hostData!.userName, '홍길동');
    expect(hostData.userId, 'discord_99999');
    expect(hostData.roomId, 7);
    expect(hostData.roomName, '재즈합주');
    expect(hostData.isHost, isTrue);
    expect(hostData.hostIp, '61.102.205.131');
    expect(hostData.port, 9999);

    // 2. 게스트 모드 URL 파싱 테스트
    const guestUrl =
        'gam://jam?user=Gamer123&uid=445566&roomId=3&isHost=false';
    final guestData = service.parseUrl(guestUrl);
    expect(guestData, isNotNull);
    expect(guestData!.userName, 'Gamer123');
    expect(guestData.userId, '445566');
    expect(guestData.roomId, 3);
    expect(guestData.isHost, isFalse);

    // 3. ZeroTier 1회용 가상 네트워크 ID 파싱 테스트
    const ztUrl =
        'gam://jam?user=Bae&uid=12345&roomId=10&ztNet=8056c2e21c000001&isHost=false';
    final ztData = service.parseUrl(ztUrl);
    expect(ztData, isNotNull);
    expect(ztData!.ztNetworkId, '8056c2e21c000001');
    expect(ztData.userName, 'Bae');
    expect(ztData.roomId, 10);
    expect(ztData.isHost, isFalse);

    // 4. 잘못된 스킴 무시 테스트
    expect(service.parseUrl('https://example.com'), isNull);
  });

  testWidgets(
    'MainLobbyScreen long press on room card triggers delete dialog',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(const MaterialApp(home: MainLobbyScreen()));
      await tester.pump();

      // Navigate to session hub
      await tester.tap(find.byTooltip('합주 세션 로비 (전체 목록)'));
      await tester.pumpAndSettle();

      // Find the room card in the session hub
      final roomCard = find.text('합주실').first;
      expect(roomCard, findsOneWidget);

      // Long press on the room card
      await tester.longPress(roomCard);
      await tester.pumpAndSettle();

      // Verify delete confirmation dialog appears
      expect(find.text('합주실 삭제'), findsOneWidget);
      expect(find.text('\'합주실\' 합주실을 삭제하시겠습니까?'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '취소'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, '삭제'), findsOneWidget);

      // Tap cancel
      await tester.tap(find.widgetWithText(TextButton, '취소'));
      await tester.pumpAndSettle();

      expect(find.text('합주실 삭제'), findsNothing);
    },
  );

  testWidgets(
    'MainLobbyScreen deleting the last room completely deletes it and shows empty state',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(const MaterialApp(home: MainLobbyScreen()));
      await tester.pump();

      // Navigate to session hub
      await tester.tap(find.byTooltip('합주 세션 로비 (전체 목록)'));
      await tester.pumpAndSettle();

      // Find the room card in the session hub
      final roomCard = find.text('합주실').first;
      expect(roomCard, findsOneWidget);

      // Long press on the room card
      await tester.longPress(roomCard);
      await tester.pumpAndSettle();

      // Tap delete button in dialog
      await tester.tap(find.widgetWithText(ElevatedButton, '삭제'));
      await tester.pumpAndSettle();

      // Verify room is deleted and empty state is shown
      expect(find.text('현재 개설된 합주실이 없습니다'), findsOneWidget);
      expect(find.text('내가 첫 번째 방장이 되어 합주실을 개설해보세요!'), findsOneWidget);
      expect(find.text('새 합주실 개설하기 (내가 방장)'), findsOneWidget);
    },
  );
}
