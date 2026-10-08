import Security
import Flutter
import MobileCoreServices
import UIKit
import WebKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, UIDropInteractionDelegate {
  private var sftpDocuments: SftpDocumentBridge?
  private var fileDropChannel: FlutterMethodChannel?
  private var fileDropInstalled = false


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

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(
      application,
      didFinishLaunchingWithOptions: launchOptions
    )
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    installSshSecrets(engineBridge.applicationRegistrar.messenger())
    sftpDocuments = SftpDocumentBridge(engineBridge.applicationRegistrar.messenger())
    engineBridge.applicationRegistrar.register(
      SitePreviewFactory(), withId: "dev.tamtoot/local_preview")
    fileDropChannel = FlutterMethodChannel(
      name: "dev.tamtoot/file_drop",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    DispatchQueue.main.async { [weak self] in self?.installFileDrop() }
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    installFileDrop()
  }

  private func installFileDrop() {
    guard !fileDropInstalled else { return }
    let sceneController = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }?
      .rootViewController as? FlutterViewController
    guard let controller =
      window?.rootViewController as? FlutterViewController ?? sceneController else {
      return
    }
    controller.view.addInteraction(UIDropInteraction(delegate: self))
    fileDropInstalled = true
  }

  func dropInteraction(
    _ interaction: UIDropInteraction,
    canHandle session: UIDropSession
  ) -> Bool {
    session.hasItemsConforming(toTypeIdentifiers: [kUTTypeItem as String])
  }

  func dropInteraction(
    _ interaction: UIDropInteraction,
    sessionDidUpdate session: UIDropSession
  ) -> UIDropProposal {
    UIDropProposal(operation: .copy)
  }

  func dropInteraction(
    _ interaction: UIDropInteraction,
    performDrop session: UIDropSession
  ) {
    let group = DispatchGroup()
    let lock = NSLock()
    var paths: [String] = []
    for item in session.items {
      guard let type = item.itemProvider.registeredTypeIdentifiers.first else {
        continue
      }
      group.enter()
      item.itemProvider.loadFileRepresentation(forTypeIdentifier: type) {
        [weak self] source, _ in
        defer { group.leave() }
        guard self != nil, let source = source else { return }
        let proposedName = item.itemProvider.suggestedName ?? source.lastPathComponent
        let safeName = proposedName.replacingOccurrences(
          of: "[^A-Za-z0-9._ -]",
          with: "_",
          options: .regularExpression
        )
        let targetFolder = FileManager.default.temporaryDirectory
          .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = targetFolder.appendingPathComponent(safeName)
        do {
          try FileManager.default.createDirectory(
            at: targetFolder,
            withIntermediateDirectories: true
          )
          try FileManager.default.copyItem(at: source, to: target)
          lock.lock()
          paths.append(target.path)
          lock.unlock()
        } catch {
          return
        }
      }
    }
    group.notify(queue: .main) { [weak self] in
      guard !paths.isEmpty else { return }
      self?.fileDropChannel?.invokeMethod("filesDropped", arguments: paths)
      DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
        for path in paths {
          try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: path).deletingLastPathComponent()
          )
        }
      }
    }
  }
}

private class SitePreviewFactory: NSObject, FlutterPlatformViewFactory {
  func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol) {
    FlutterStandardMessageCodec.sharedInstance()
  }
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    SitePreview(frame: frame, arguments: args)
  }
}

private class SitePreview: NSObject, FlutterPlatformView {
  private let webView: WKWebView
  init(frame: CGRect, arguments: Any?) {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    webView = WKWebView(frame: frame, configuration: configuration)
    super.init()
    if let params = arguments as? [String: Any], let text = params["url"] as? String,
       let url = URL(string: text), ["http", "https"].contains(url.scheme ?? "") {
      webView.load(URLRequest(url: url))
    }
  }
  func view() -> UIView { webView }
}

/// User-scoped binary import/export. No permanent bookmark or broad file access.
private final class SftpDocumentBridge: NSObject, UIDocumentPickerDelegate {
  private var pending: FlutterResult?
  private var exporting = false
  private var temporary: URL?
  init(_ messenger: FlutterBinaryMessenger) {
    super.init()
    FlutterMethodChannel(name: "dev.tamtoot/sftp_files", binaryMessenger: messenger)
      .setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
  }
  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard pending == nil else { result(FlutterError(code: "BUSY", message: "Document picker is open", details: nil)); return }
    let root = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }.first { $0.isKeyWindow }?.rootViewController
    guard var controller = root else { result(FlutterError(code: "FILE", message: "No document window available", details: nil)); return }
    while let next = controller.presentedViewController { controller = next }
    let picker: UIDocumentPickerViewController
    if call.method == "pick" {
      exporting = false
      picker = UIDocumentPickerViewController(documentTypes: [kUTTypeData as String], in: .open)
    } else if call.method == "save" {
      guard let args = call.arguments as? [String: Any], let bytes = args["bytes"] as? FlutterStandardTypedData,
            bytes.data.count <= 32 * 1024 * 1024 else {
        result(FlutterError(code: "FILE", message: "File exceeds 32 MiB", details: nil)); return
      }
      do {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sftp-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporary = directory
        let raw = args["name"] as? String ?? "download"
        let name = raw.components(separatedBy: CharacterSet(charactersIn: "/\\").union(.controlCharacters)).joined(separator: "_")
        let file = directory.appendingPathComponent(name.isEmpty ? "download" : name)
        try bytes.data.write(to: file, options: .atomic)
        exporting = true; picker = UIDocumentPickerViewController(url: file, in: .exportToService)
      } catch { cleanup(); result(FlutterError(code: "FILE", message: "Unable to prepare export", details: nil)); return }
    } else { result(FlutterMethodNotImplemented); return }
    pending = result; picker.delegate = self; picker.allowsMultipleSelection = false
    controller.present(picker, animated: true)
  }
  private func cleanup() {
    if let directory = temporary { try? FileManager.default.removeItem(at: directory) }
    temporary = nil
  }
  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    let reply = pending; pending = nil; cleanup(); reply?(exporting ? false : nil)
  }
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    let reply = pending; pending = nil
    if exporting { cleanup(); reply?(true); return }
    guard let url = urls.first else { reply?(nil); return }
    DispatchQueue.global(qos: .userInitiated).async {
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      do {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value <= 32 * 1024 * 1024 else {
          throw NSError(domain: "SFTP", code: 1)
        }
        var bytes: Data?; var readError: Error?; var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { source in
          do {
            guard let input = InputStream(url: source) else { throw NSError(domain: "SFTP", code: 3) }
            input.open(); defer { input.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 32768)
            while true {
              let count = input.read(&buffer, maxLength: buffer.count)
              if count == 0 { break }
              guard count > 0, data.count + count <= 32 * 1024 * 1024 else { throw NSError(domain: "SFTP", code: 4) }
              data.append(contentsOf: buffer.prefix(count))
            }
            bytes = data
          } catch { readError = error }
        }
        guard coordinationError == nil, readError == nil, let data = bytes, data.count <= 32 * 1024 * 1024 else {
          throw NSError(domain: "SFTP", code: 2)
        }
        DispatchQueue.main.async { reply?(["name": url.lastPathComponent, "bytes": FlutterStandardTypedData(bytes: data)]) }
      } catch {
        DispatchQueue.main.async { reply?(FlutterError(code: "FILE", message: "Document read failed or exceeded 32 MiB", details: nil)) }
      }
    }
  }
}
