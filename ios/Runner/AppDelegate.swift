import Security
import Flutter
import MobileCoreServices
import UIKit
import WebKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, UIDropInteractionDelegate {
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
