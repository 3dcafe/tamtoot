import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../features/ide_shell.dart';
import 'providers.dart';

class TamtootApp extends ConsumerStatefulWidget {
  const TamtootApp({super.key});
  @override
  ConsumerState<TamtootApp> createState() => _TamtootAppState();
}

class _TamtootAppState extends ConsumerState<TamtootApp>
    with WidgetsBindingObserver {
  static const _windowChannel = MethodChannel('dev.tamtoot/window');
  String? _lastWindowTitle;

  Future<void> _updateWindowTitle(String title, bool dirty) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.macOS) return;
    if (_lastWindowTitle == title) return;
    _lastWindowTitle = title;
    try {
      await _windowChannel.invokeMethod<void>('setTitle', {
        'title': title,
        'dirty': dirty,
      });
    } on MissingPluginException {
      // Widget tests and older native hosts may not expose the window channel.
      _lastWindowTitle = null;
    } on PlatformException {
      _lastWindowTitle = null;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(ref.read(sessionProvider).persistNow());
    } else {
      unawaited(ref.read(sessionProvider).refreshGitIndicators());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(sessionChangesProvider);
    final session = ref.watch(sessionProvider);
    final root = session.workspaceRoot;
    final projectName = root?.pathSegments
        .where((segment) => segment.isNotEmpty)
        .lastOrNull;
    final document = session.documents.active;
    final dirty = document?.dirty ?? false;
    final title = [
      'TamToot',
      if (root != null) projectName ?? root.toString(),
      if (document != null) '${document.name}${dirty ? ' *' : ''}',
    ].join(' — ');
    unawaited(_updateWindowTitle(title, dirty));
    final theme = session.theme;
    final colors = ColorScheme.fromSeed(
      seedColor: Color(theme.color('accent')),
      brightness: theme.dark ? Brightness.dark : Brightness.light,
    );
    return MaterialApp(
      title: title,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: colors,
        scaffoldBackgroundColor: Color(theme.color('shell')),
        canvasColor: Color(theme.color('panel')),
        dividerColor: Color(theme.color('border')),
        textTheme: ThemeData(
          brightness: theme.dark ? Brightness.dark : Brightness.light,
        ).textTheme,
        inputDecorationTheme: const InputDecorationTheme(
          isDense: true,
          border: OutlineInputBorder(),
        ),
        tooltipTheme: const TooltipThemeData(
          waitDuration: Duration(milliseconds: 500),
        ),
        scrollbarTheme: ScrollbarThemeData(
          thickness: const WidgetStatePropertyAll(6),
          thumbColor: WidgetStatePropertyAll(
            Color(theme.color('muted')).withValues(alpha: .5),
          ),
        ),
      ),
      home: const IdeShell(),
    );
  }
}
