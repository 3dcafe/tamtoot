import '../commands/commands.dart';
import '../filesystem/filesystem.dart';
import '../settings/settings.dart';
import '../themes/ide_theme.dart';
import '../../languages/language_registry.dart';
import '../../editor/document/editor_controller.dart';

/// Executable API version 1. Only trusted, compiled-in extensions in v0.1.
/// Runtime loading of arbitrary Dart code is deliberately not supported.
abstract interface class IdePlugin {
  String get id;
  String get version;
  int get apiVersion;
  Future<void> activate(PluginContext context);
  Future<void> deactivate();
}

/// Host-owned, scoped capabilities; never expose UI state providers.
abstract interface class PluginContext {
  CommandRegistry get commands;
  WorkspaceAccess get workspace;
  FileSystemProvider get filesystem;
  EditorAccess get editors;
  LanguageRegistry get languages;
  DiagnosticAccess get diagnostics;
  SettingsService get settings;
  ThemeAccess get themes;
  NotificationAccess get notifications;
  TerminalService get terminals;
  PanelRegistry get ui;
}

abstract interface class WorkspaceAccess {
  Uri? get root;
  Stream<Uri?> get changes;
}

abstract interface class EditorAccess {
  EditorController? get active;
  Future<void> open(Uri document);
}

abstract interface class DiagnosticAccess {
  /// Replace diagnostics for one owner. Revision guards stale provider results.
  void publish(
    String owner,
    Uri document,
    int revision,
    List<LanguageDiagnostic> items,
  );
  void clear(String owner);
}

abstract interface class ThemeAccess {
  void register(IdeTheme theme);
}

abstract interface class NotificationAccess {
  void show(String message, {bool error = false});
}

class PanelDescriptor {
  const PanelDescriptor(this.id, this.title, this.viewType);
  final String id, title, viewType;
}

abstract interface class PanelRegistry {
  /// Presentation adapters interpret viewType; domain API never accepts Widgets.
  void register(PanelDescriptor panel);
  void unregister(String id);
}

abstract interface class TerminalSession {
  String get id;
  Stream<String> get output;
  Future<void> write(String input);
  Future<void> resize(int columns, int rows);
  Future<void> close();
}

abstract interface class TerminalService {
  bool get available;
  Future<TerminalSession> create({Uri? workingDirectory});
}

abstract interface class ProcessService {
  Future<int> run(
    String executable,
    List<String> arguments, {
    Uri? workingDirectory,
  });
}

abstract interface class ScmService {
  Future<List<Uri>> changedFiles(Uri workspace);
}

abstract interface class DebugService {
  Future<void> launch(Uri configuration);
  Future<void> stop();
}

/// Reserved capability identifiers. They are declarations, not a sandbox.
enum PluginPermission {
  filesystemRead,
  filesystemWrite,
  processExecute,
  network,
  terminal,
  scm,
}
