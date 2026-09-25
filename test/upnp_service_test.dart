import 'package:flutter_test/flutter_test.dart';
import 'package:gam/services/upnp_service.dart';

void main() {
  test('UpnpService initializes, detects local IP and attempts port mapping', () async {
    final upnp = UpnpService();
    expect(upnp.isPortMapped, isFalse);
    expect(upnp.mappedPort, 9999);

    final localIp = await upnp.detectLocalLanIp();
    expect(localIp, isNotEmpty);
    print('Local LAN IP detected: $localIp');

    // Run openPort with small timeout
    final opened = await upnp.openPort(port: 9999);
    print('UPnP Open Port Result: $opened');
    print('Status: ${upnp.statusMessage}');
    print('Public IP: ${upnp.publicIp}');

    expect(upnp.statusMessage, isNotEmpty);

    await upnp.closePort();
    expect(upnp.isPortMapped, isFalse);
  });
}
