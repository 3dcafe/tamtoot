import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app/app.dart';
import 'app/bootstrap.dart';
import 'app/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final session = await bootstrap();
    runApp(
      ProviderScope(
        overrides: [sessionProvider.overrideWithValue(session)],
        child: const TamtootApp(),
      ),
    );
  } catch (error, stack) {
    debugPrint('$error\n$stack');
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SelectableText('Tamtoot could not start.\n$error'),
          ),
        ),
      ),
    );
  }
}
