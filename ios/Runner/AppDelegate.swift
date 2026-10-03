import Flutter
import MobileCoreServices
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, UIDropInteractionDelegate {
  private var fileDropChannel: FlutterMethodChannel?
  private var fileDropInstalled = false

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
