import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var deepLinkChannel: FlutterMethodChannel?
  private var pendingUrl: String?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    let controller = mainFlutterWindow?.contentViewController as! FlutterViewController
    deepLinkChannel = FlutterMethodChannel(
      name: "com.example.gam/deeplink",
      binaryMessenger: controller.engine.binaryMessenger
    )

    deepLinkChannel?.setMethodCallHandler { [weak self] (call, result) in
      if call.method == "getInitialUrl" {
        result(self?.pendingUrl)
        self?.pendingUrl = nil
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    super.applicationDidFinishLaunching(notification)
  }

  override func application(_ application: NSApplication, open urls: [URL]) {
    guard let url = urls.first?.absoluteString else { return }
    if let channel = deepLinkChannel {
      channel.invokeMethod("onDeepLink", arguments: url)
    } else {
      pendingUrl = url
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
