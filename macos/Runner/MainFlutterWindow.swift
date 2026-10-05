import Security
import Cocoa
import FlutterMacOS
import WebKit

class MainFlutterWindow: NSWindow {
  private var windowChannel: FlutterMethodChannel?
  private var bookmarkChannel: FlutterMethodChannel?
  private var fileDropChannel: FlutterMethodChannel?
  private var scopedUrls: [String: URL] = [:]


  private var sshSecretsChannel: FlutterMethodChannel?
  private func installSshSecrets(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "dev.tamtoot/ssh_secrets", binaryMessenger: messenger)
    sshSecretsChannel = channel
    channel.setMethodCallHandler { call, result in
      if call.method == "available" { result(true); return }
      guard let args = call.arguments as? [String: Any],
            let id = args["id"] as? String,
            id.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil else {
        result(FlutterError(code: "invalid_reference", message: "Invalid secret reference", details: nil)); return
      }
      let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dev.tamtoot.ssh", kSecAttrAccount as String: id,
        kSecAttrSynchronizable as String: false]
      var status: OSStatus
      switch call.method {
      case "write":
        guard let value = args["value"] as? FlutterStandardTypedData,
              !value.data.isEmpty, value.data.count <= 65536 else {
          result(FlutterError(code: "invalid_value", message: "Invalid secret size", details: nil)); return
        }
        let attributes: [String: Any] = [kSecValueData as String: value.data,
          kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
          status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
      case "read":
        var readQuery = query
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        status = SecItemCopyMatching(readQuery as CFDictionary, &item)
        if status == errSecItemNotFound { result(nil); return }
        if status == errSecSuccess, let data = item as? Data {
          result(FlutterStandardTypedData(bytes: data)); return
        }
      case "delete":
        status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound { status = errSecSuccess }
      default: result(FlutterMethodNotImplemented); return
      }
      if status == errSecSuccess { result(nil) }
      else { result(FlutterError(code: "secure_storage", message: "Keychain operation failed (\(status))", details: nil)) }
    }
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    flutterViewController.registrar(forPlugin: "TamTootNativePreview")
      .register(SitePreviewFactory(), withId: "dev.tamtoot/local_preview")

    super.awakeFromNib()
    self.title = "TamToot"

    let messenger = flutterViewController.engine.binaryMessenger
    installSshSecrets(messenger)
    fileDropChannel = FlutterMethodChannel(
      name: "dev.tamtoot/file_drop",
      binaryMessenger: messenger
    )
    registerForDraggedTypes([.fileURL])
    let window = FlutterMethodChannel(
      name: "dev.tamtoot/window",
      binaryMessenger: messenger
    )
    windowChannel = window
    window.setMethodCallHandler { [weak self] call, result in
      guard call.method == "setTitle" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let arguments = call.arguments as? [String: Any],
            let title = arguments["title"] as? String,
            let dirty = arguments["dirty"] as? Bool else {
        result(FlutterError(
          code: "invalid_arguments",
          message: "Expected title and dirty",
          details: nil
        ))
        return
      }
      self?.title = title
      self?.isDocumentEdited = dirty
      result(nil)
    }

    let bookmarks = FlutterMethodChannel(
      name: "dev.tamtoot/bookmarks",
      binaryMessenger: messenger
    )
    bookmarkChannel = bookmarks
    bookmarks.setMethodCallHandler { [weak self] call, result in
      self?.handleBookmark(call: call, result: result)
    }
  }

  func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    let urls = sender.draggingPasteboard.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]
    ) as? [URL]
    return urls?.isEmpty == false ? .copy : []
  }

  func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    guard let urls = sender.draggingPasteboard.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]
    ) as? [URL], !urls.isEmpty else {
      return false
    }
    fileDropChannel?.invokeMethod(
      "filesDropped",
      arguments: urls.map { $0.path }
    )
    return true
  }

  private func handleBookmark(
    call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    switch call.method {
    case "createBookmark":
      guard let arguments = call.arguments as? [String: Any],
            let path = arguments["path"] as? String else {
        result(FlutterError(
          code: "invalid_arguments",
          message: "Expected path",
          details: nil
        ))
        return
      }
      let url = URL(fileURLWithPath: path, isDirectory: true)
      do {
        let data = try url.bookmarkData(
          options: [.withSecurityScope],
          includingResourceValuesForKeys: nil,
          relativeTo: nil
        )
        result(data.base64EncodedString())
      } catch {
        result(FlutterError(
          code: "bookmark_failed",
          message: error.localizedDescription,
          details: nil
        ))
      }

    case "beginAccess":
      guard let arguments = call.arguments as? [String: Any],
            let bookmark = arguments["bookmark"] as? String,
            let data = Data(base64Encoded: bookmark) else {
        result(FlutterError(
          code: "invalid_arguments",
          message: "Expected bookmark",
          details: nil
        ))
        return
      }
      do {
        var isStale = false
        let url = try URL(
          resolvingBookmarkData: data,
          options: [.withSecurityScope],
          relativeTo: nil,
          bookmarkDataIsStale: &isStale
        )
        guard url.startAccessingSecurityScopedResource() else {
          result(FlutterError(
            code: "access_denied",
            message: "Could not start security-scoped access",
            details: nil
          ))
          return
        }
        let path = url.path
        if let previous = scopedUrls.removeValue(forKey: path) {
          previous.stopAccessingSecurityScopedResource()
        }
        scopedUrls[path] = url
        result(path)
      } catch {
        result(FlutterError(
          code: "bookmark_resolve_failed",
          message: error.localizedDescription,
          details: nil
        ))
      }

    case "endAccess":
      guard let arguments = call.arguments as? [String: Any],
            let path = arguments["path"] as? String else {
        result(FlutterError(
          code: "invalid_arguments",
          message: "Expected path",
          details: nil
        ))
        return
      }
      if let url = scopedUrls.removeValue(forKey: path) {
        url.stopAccessingSecurityScopedResource()
      }
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

private class SitePreviewFactory: NSObject, FlutterPlatformViewFactory {
  func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol)? {
    FlutterStandardMessageCodec.sharedInstance()
  }
  func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.autoresizingMask = [.width, .height]
    if let params = args as? [String: Any], let text = params["url"] as? String,
       let url = URL(string: text), ["http", "https"].contains(url.scheme ?? "") {
      view.load(URLRequest(url: url))
    }
    return view
  }
}
