import 'dart:async';
import 'dart:convert';
import '../core/commands/commands.dart';
import '../core/filesystem/filesystem.dart';
import '../core/persistence/schema.dart';
import '../core/settings/settings.dart';
import '../core/themes/ide_theme.dart';
import '../languages/language_registry.dart';
import '../workspace/documents/document_service.dart';
import '../workspace/layout/dock_layout.dart';

/// Application orchestration. UI observes events through a Riverpod adapter.
class IdeSession {
  IdeSession({required this.store, required this.documents});
  final PersistenceStore store;
  final DocumentService documents;
  final commands = CommandRegistry();
  KeybindingRegistry keys = KeybindingRegistry();
  final settings = SettingsService();
  final languages = LanguageRegistry();
  final Map<String, IdeTheme> themes = {};
  DockLayout layout = DockLayout.defaultLayout;
  final _events = StreamController<int>.broadcast(sync: true);
  Stream<int> get changes => _events.stream;
  int _revision = 0;
  final List<String> output = [];
  final List<String> errors = [];
  final List<String> recentWorkspaces = [];
  Uri? workspaceRoot;
  List<FileEntry> entries = [];
  String message = 'Ready';
  bool findVisible = false;
  bool replaceVisible = false;
  String findQuery = '', replacement = '';
  final Map<String, StreamSubscription<void>> _subscriptions = {};
  Timer? _saveTimer;
  Future<void> _pendingSave = Future.value();
  bool _disposed = false;
  IdeTheme get theme => themes[settings.theme] ?? themes.values.first;
  void changed({bool persist = true}) {
    if (_disposed) return;
    _events.add(++_revision);
    if (persist) {
      _saveTimer?.cancel();
      _saveTimer = Timer(const Duration(milliseconds: 450), () {
        unawaited(persistNow());
      });
    }
  }

  void log(String value, {bool error = false}) {
    message = value;
    output.add(value);
    if (output.length > 500) output.removeAt(0);
    if (error) errors.add(value);
    changed(persist: false);
  }

  void observe(OpenDocument doc) {
    if (_subscriptions.containsKey(doc.id)) return;
    configure(doc);
    _subscriptions[doc.id] = doc.editor.changes.listen((_) => changed());
  }

  void configure(OpenDocument doc) {
    doc.editor.tabSize = settings.get('tabSize') as int;
    doc.editor.insertSpaces = settings.get('insertSpaces') as bool;
    doc.editor.readOnly = settings.get('readOnly') as bool;
  }

  Future<void> run(String id, [Object? argument]) async {
    try {
      await commands.execute(id, argument);
    } catch (e) {
      log('$id: $e', error: true);
    }
  }

  Future<void> restore() async {
    Future<void> load(String key, void Function(String) apply) async {
      try {
        final data = await store.read(key);
        if (data != null) apply(data);
      } catch (e) {
        log('Could not restore $key: $e', error: true);
      }
    }

    await load('settings', settings.restore);
    await load('layout', (data) => layout = DockLayout.parse(data));
    await load('keybindings', (data) => keys = KeybindingRegistry.parse(data));
    await load('session', (source) {
      final data = decodeVersioned(source, 'Session');
      final raw = data['documents'];
      if (raw is! List) {
        throw const SchemaException('Invalid session documents');
      }
      // Validate completely before mutating the current workspace.
      final normalized = <Map<String, dynamic>>[];
      for (final d in raw) {
        if (d is! Map<String, dynamic>) {
          throw const SchemaException('Invalid document');
        }
        requiredString(d, 'name');
        if (d['text'] is! String ||
            (d['savedText'] != null && d['savedText'] is! String) ||
            (d['uri'] != null && d['uri'] is! String)) {
          throw const SchemaException('Invalid document fields');
        }
        normalized.add(d);
      }
      final recent = stringList(
        data['recentWorkspaces'] ?? [],
        'recentWorkspaces',
      );
      for (final d in normalized) {
        final doc = documents.create(
          d['name'] as String,
          d['text'] as String,
          uri: d['uri'] == null ? null : Uri.parse(d['uri'] as String),
          savedText: d['savedText'] as String?,
        );
        observe(doc);
      }
      final active = data['activeIndex'];
      if (active is int && active >= 0 && active < documents.documents.length) {
        documents.activeId = documents.documents[active].id;
      }
      recentWorkspaces.addAll(recent.take(10));
    });
    if (documents.documents.isEmpty) {
      observe(
        documents.create(
          'welcome.dart',
          "// Welcome to Tamtoot\n// Your workspace, on every screen.\n\nclass Workspace {\n  final String name;\n\n  const Workspace(this.name);\n\n  void open() {\n    print('Hello, \$name!');\n  }\n}\n\nvoid main() {\n  const workspace = Workspace('Tamtoot');\n  workspace.open();\n}\n",
        ),
      );
      observe(
        documents.create(
          'Program.cs',
          '// C# language package • v0.1\nusing System;\n\nnamespace Hello;\n\npublic class Program\n{\n    public static void Main()\n    {\n        Console.WriteLine("Create something great.");\n    }\n}\n',
        ),
      );
      documents.activeId = documents.documents.first.id;
    }
    log(
      'Foundation ready · ${languages.languages.length} language packages · API v1',
    );
  }

  Future<void> persistNow() {
    _saveTimer?.cancel();
    final snapshot = {
      'settings': settings.encode(),
      'layout': layout.encode(),
      'keybindings': jsonEncode(keys.toJson()),
      'session': jsonEncode({
        'schemaVersion': 1,
        'activeIndex': documents.documents.indexWhere(
          (d) => d.id == documents.activeId,
        ),
        'recentWorkspaces': recentWorkspaces,
        'documents': [
          for (final d in documents.documents)
            {
              'name': d.name,
              'uri': d.uri?.toString(),
              'text': d.editor.text,
              'savedText': d.savedText,
            },
        ],
      }),
    };
    _pendingSave = _pendingSave.then((_) async {
      try {
        for (final e in snapshot.entries) {
          await store.write(e.key, e.value);
        }
      } catch (e) {
        log('Persistence failed: $e', error: true);
      }
    });
    return _pendingSave;
  }

  Future<void> dispose() async {
    _saveTimer?.cancel();
    await persistNow();
    _disposed = true;
    for (final s in _subscriptions.values) {
      await s.cancel();
    }
    for (final d in documents.documents) {
      await d.editor.dispose();
    }
    await _events.close();
  }
}
