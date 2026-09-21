import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    if let screen = NSScreen.main {
      self.setFrame(screen.visibleFrame, display: true)
    } else {
      let windowFrame = self.frame
      self.setFrame(windowFrame, display: true)
    }
    self.minSize = NSSize(width: 1024, height: 680)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
