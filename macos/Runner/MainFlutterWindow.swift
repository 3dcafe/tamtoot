import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var windowChannel: FlutterMethodChannel?
  private var bookmarkChannel: FlutterMethodChannel?
  private var fileDropChannel: FlutterMethodChannel?
  private var scopedUrls: [String: URL] = [:]

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
    self.title = "TamToot"

    let messenger = flutterViewController.engine.binaryMessenger
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
