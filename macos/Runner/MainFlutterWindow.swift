import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var windowChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
    self.title = "TamToot"

    let channel = FlutterMethodChannel(
      name: "dev.tamtoot/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    windowChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "setTitle" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let arguments = call.arguments as? [String: Any],
            let title = arguments["title"] as? String,
            let dirty = arguments["dirty"] as? Bool else {
        result(FlutterError(code: "invalid_arguments", message: "Expected title and dirty", details: nil))
        return
      }
      self?.title = title
      self?.isDocumentEdited = dirty
      result(nil)
    }
  }
}
