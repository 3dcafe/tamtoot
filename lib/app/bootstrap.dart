import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/themes/ide_theme.dart';
import '../languages/language_registry.dart';
import '../languages/package_service.dart';
import '../platform/platform_services.dart';
import '../workspace/documents/document_service.dart';
import 'ide_session.dart';

Future<IdeSession> bootstrap() async {
  final files = PlatformFiles();
  final session = IdeSession(
    store: PreferenceStore(await SharedPreferences.getInstance()),
    documents: DocumentService(files, files),
  );
  for (final id in ['night', 'day']) {
    final theme = IdeTheme.parse(
      await rootBundle.loadString('assets/themes/$id.json'),
    );
    session.themes[theme.id] = theme;
  }
  for (final id in ['dart', 'csharp']) {
    try {
      final base = 'assets/languages/$id';
      session.languages.register(
        LanguagePackageLoader().load(
          await rootBundle.loadString('$base/language.json'),
          await rootBundle.loadString('$base/syntax.json'),
          snippets: await rootBundle.loadString('$base/snippets.json'),
        ),
      );
    } catch (e) {
      session.log('Language $id: $e', error: true);
    }
  }
  await PackageService(
    session.store,
    session.languages,
  ).restore((error) => session.log('Package restore: $error', error: true));
  await session.restore();
  return session;
}
