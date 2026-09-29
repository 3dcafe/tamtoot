import '../git/git_store.dart';
import 'http_request.dart';

class RequestEntry {
  const RequestEntry({required this.path, required this.name, required this.method, this.error});
  final String path, name, method;
  final String? error;
  bool get valid => error == null;
}

class RequestStorage {
  RequestStorage(this.store);
  final GitRepositoryStore store;
  static const root = '.tamtoot/requests';
  static const projectEnvironmentPath = '.tamtoot/environment.json';
  static const localEnvironmentPath = '.tamtoot/environment.local.json';

  String _requestPath(String path, {String extension = '.json'}) {
    final normalized = path.replaceAll('\\', '/').replaceAll(RegExp(r'^/+|/+$'), '');
    final parts = normalized.split('/');
    if (normalized.isEmpty || parts.any((part) => part.isEmpty || part == '.' || part == '..') || !normalized.toLowerCase().endsWith(extension)) {
      throw const FormatException('Path must remain inside .tamtoot/requests.');
    }
    return '$root/$normalized';
  }

  String _folder(String folder) {
    final normalized = folder.replaceAll('\\', '/').replaceAll(RegExp(r'^/+|/+$'), '');
    if (normalized.isEmpty) return root;
    if (normalized.split('/').any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw const FormatException('Folder must remain inside .tamtoot/requests.');
    }
    return '$root/$normalized';
  }

  static String safeName(String value) {
    final slug = value.toLowerCase().trim().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    if (slug.isEmpty) return 'request';
    return slug.length > 80 ? slug.substring(0, 80) : slug;
  }

  Future<List<RequestEntry>> list() async {
    if (!await store.exists(root)) return const [];
    final paths = await store.listFiles(root);
    final requestPaths = paths
        .where(
          (path) =>
              path.startsWith('$root/') &&
              path.toLowerCase().endsWith('.json') &&
              !path.endsWith('.tmp'),
        )
        .toList();
    final loaded = List<RequestEntry?>.filled(requestPaths.length, null);
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final index = next++;
        if (index >= requestPaths.length) return;
        final fullPath = requestPaths[index];
        final relative = fullPath.substring(root.length + 1);
        try {
          final request = HttpRequestFile.parse(await store.readText(fullPath));
          loaded[index] = RequestEntry(
            path: relative,
            name: request.name,
            method: request.method,
          );
        } catch (error) {
          loaded[index] = RequestEntry(
            path: relative,
            name: relative.split('/').last,
            method: 'ERR',
            error: '$error',
          );
        }
      }
    }
    final workers = requestPaths.length.clamp(0, 8);
    await Future.wait(List.generate(workers, (_) => worker()));
    final entries = loaded.whereType<RequestEntry>().toList();
    entries.sort((a, b) => a.path.compareTo(b.path));
    return entries;
  }

  Future<HttpRequestFile> read(String path) async => HttpRequestFile.parse(await store.readText(_requestPath(path)));

  Future<RequestEntry> create(String folder, HttpRequestFile request) async {
    request.validate();
    final relative = [if (folder.trim().isNotEmpty) folder, '${safeName(request.name)}.json'].join('/');
    final path = _requestPath(relative);
    if (await store.exists(path)) throw StateError('Request already exists: $relative');
    await store.validateRegularFilePath(path);
    await store.createDirectory(_folder(folder));
    await store.writeText(path, '${request.encode()}\n');
    return RequestEntry(path: relative, name: request.name, method: request.method);
  }

  Future<void> createFolder(String folder) async {
    final path = _folder(folder);
    await store.validateRegularFilePath(path);
    await store.createDirectory(path);
  }

  Future<void> save(String path, HttpRequestFile request) async {
    request.validate();
    final target = _requestPath(path);
    await store.validateRegularFilePath(target);
    await store.writeText(target, '${request.encode()}\n');
  }

  Future<RequestEntry> rename(String path, String newName) async {
    final request = await read(path);
    final slash = path.lastIndexOf('/');
    final folder = slash < 0 ? '' : path.substring(0, slash);
    final target = [if (folder.isNotEmpty) folder, '${safeName(newName)}.json'].join('/');
    final targetPath = _requestPath(target);
    if (await store.exists(targetPath)) throw StateError('Request already exists: $target');
    await store.validateRegularFilePath(targetPath);
    final changed = HttpRequestFile(name: newName.trim(), method: request.method, url: request.url, headers: request.headers, query: request.query, body: request.body, auth: request.auth, attachments: request.attachments);
    await store.writeText(targetPath, '${changed.encode()}\n');
    await store.delete(_requestPath(path));
    return RequestEntry(path: target, name: changed.name, method: changed.method);
  }

  Future<RequestEntry> move(String path, String targetFolder) async {
    final request = await read(path);
    final filename = path.split('/').last;
    final target = [if (targetFolder.trim().isNotEmpty) targetFolder, filename].join('/');
    final targetPath = _requestPath(target);
    if (await store.exists(targetPath)) throw StateError('Request already exists: $target');
    await store.validateRegularFilePath(targetPath);
    final sourceFolder = _requestPath(path).split('/')..removeLast();
    final targetDirectory = _folder(targetFolder);
    for (final attachment in request.attachments) {
      final destination = '$targetDirectory/${attachment.path}';
      await store.validateRegularFilePath(destination);
      if (await store.exists(destination)) {
        throw StateError('Documentation already exists: ${attachment.path}');
      }
    }
    await store.createDirectory(_folder(targetFolder));
    await store.writeText(targetPath, '${request.encode()}\n');
    for (final attachment in request.attachments) {
      final source = '${sourceFolder.join('/')}/${attachment.path}';
      final destination = '$targetDirectory/${attachment.path}';
      if (await store.exists(source)) {
        await store.writeBytes(destination, await store.readBytes(source));
        await store.delete(source);
      }
    }
    await store.delete(_requestPath(path));
    return RequestEntry(path: target, name: request.name, method: request.method);
  }

  Future<void> delete(String path) => store.delete(_requestPath(path));

  String _attachmentPath(String requestPath, String attachmentPath) {
    if (!RequestAttachment.isSafeMarkdownPath(attachmentPath)) {
      throw const FormatException(
        'Attachment path must remain beside the request.',
      );
    }
    final request = _requestPath(requestPath);
    final folder = request.substring(0, request.lastIndexOf('/'));
    final raw = attachmentPath.replaceAll('\\', '/');
    return '$folder/$raw';
  }

  Future<String> readMarkdown(String requestPath, String attachmentPath) async {
    final path = _attachmentPath(requestPath, attachmentPath);
    if (!await store.exists(path)) throw StateError('Documentation file not found.');
    return store.readText(path);
  }

  Future<void> saveMarkdown(String requestPath, String attachmentPath, String content, {bool overwrite = true}) async {
    final path = _attachmentPath(requestPath, attachmentPath);
    if (!overwrite && await store.exists(path)) throw StateError('Documentation already exists.');
    await store.validateRegularFilePath(path);
    await store.writeText(path, content);
  }

  Future<({RequestEnvironment project, RequestEnvironment local})> loadEnvironment() async => (
    project: RequestEnvironment.parse(await store.exists(projectEnvironmentPath) ? await store.readText(projectEnvironmentPath) : null),
    local: RequestEnvironment.parse(await store.exists(localEnvironmentPath) ? await store.readText(localEnvironmentPath) : null),
  );

  Future<void> saveProjectEnvironment(RequestEnvironment environment) async {
    await store.validateRegularFilePath(projectEnvironmentPath);
    await store.writeText(projectEnvironmentPath, '${environment.encode()}\n');
  }

  Future<void> saveLocalEnvironment(RequestEnvironment environment) async {
    await store.validateRegularFilePath(localEnvironmentPath);
    await store.writeText(
      localEnvironmentPath,
      '${environment.encode(includeAuth: false)}\n',
    );
  }
}
