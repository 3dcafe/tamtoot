import 'dart:async';
import 'package:flutter/material.dart';
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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(ref.read(sessionProvider).persistNow());
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
    final theme = session.theme;
    final colors = ColorScheme.fromSeed(
      seedColor: Color(theme.color('accent')),
      brightness: theme.dark ? Brightness.dark : Brightness.light,
    );
    return MaterialApp(
      title: 'Tamtoot IDE',
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
