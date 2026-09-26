import 'dart:convert';
import '../core/filesystem/filesystem.dart';
import '../core/persistence/schema.dart';
import 'language_registry.dart';

/// Transactional package installation: validate, persist, then publish.
class PackageService {
  PackageService(this.store, this.registry);
  final PersistenceStore store;
  final LanguageRegistry registry;
  Future<LanguageDefinition> install(
    String manifest,
    String syntax,
    String? snippets,
  ) async {
    final language = LanguagePackageLoader().load(
      manifest,
      syntax,
      snippets: snippets,
    );
    if (!RegExp(r'^[a-z][a-z0-9_-]*$').hasMatch(language.id)) {
      throw const SchemaException('Invalid package id');
    }
    final ids = await _ids();
    await store.write(
      'language.${language.id}',
      jsonEncode({
        'schemaVersion': 1,
        'manifest': manifest,
        'syntax': syntax,
        'snippets': snippets,
      }),
    );
    if (!ids.contains(language.id)) ids.add(language.id);
    await store.write(
      'language.index',
      jsonEncode({'schemaVersion': 1, 'ids': ids}),
    );
    registry.register(language);
    return language;
  }

  Future<List<String>> _ids() async {
    final raw = await store.read('language.index');
    return raw == null
        ? []
        : stringList(decodeVersioned(raw, 'Package index')['ids'], 'ids');
  }

  Future<void> restore(void Function(String) onError) async {
    try {
      for (final id in await _ids()) {
        try {
          final raw = await store.read('language.$id');
          if (raw == null) throw SchemaException('Missing package $id');
          final data = decodeVersioned(raw, 'Installed package');
          registry.register(
            LanguagePackageLoader().load(
              requiredString(data, 'manifest'),
              requiredString(data, 'syntax'),
              snippets: data['snippets'] as String?,
            ),
          );
        } catch (e) {
          onError('$id: $e');
        }
      }
    } catch (e) {
      onError('$e');
    }
  }
}
