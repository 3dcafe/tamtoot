import 'dart:convert';
import '../core/git/git_service.dart';
import '../core/git/http_git_service.dart';
import '../workspace/documents/document_service.dart';
import 'ide_session.dart';

String? gitText(List<int>? bytes) {
  if (bytes == null) return null;
  if (bytes.contains(0)) throw const FormatException('Binary file');
  return utf8.decode(bytes);
}

class FileChangeReview {
  const FileChangeReview(
    this.snapshot,
    this.document,
    this.revision,
    this.unsavedText,
  );
  final GitFileSnapshot snapshot;
  final OpenDocument? document;
  final int? revision;
  final String? unsavedText;
}

extension GitFileChanges on IdeSession {
  Future<void> addFileToGitignore(Uri uri) async {
    if (gitBusy) throw GitException('Another Git operation is running');
    final provider = git;
    final root = workspaceRoot;
    final path = gitPath(uri);
    if (provider is! HttpGitService ||
        root == null ||
        path == null ||
        path == '.gitignore' ||
        path.split('/').contains('..') ||
        path.startsWith('.git/') ||
        RegExp(r'[\r\n\x00]').hasMatch(path)) {
      throw GitException('Cannot add this file to .gitignore');
    }
    gitBusy = true;
    changed(persist: false);
    try {
      final store = provider.openStore(root);
      await store.validateRegularFilePath('.gitignore');
      final ignoreUri = root.resolve('.gitignore');
      final doc = documents.documents
          .where((d) => d.uri == ignoreUri)
          .firstOrNull;
      if (doc?.editor.readOnly == true) {
        throw GitException('.gitignore is read-only');
      }
      final text =
          doc?.editor.text ??
          (await store.exists('.gitignore')
              ? await store.readText('.gitignore')
              : '');
      final escaped = path.replaceAllMapped(
        RegExp(r'[\\*?\[\] #!]'),
        (m) => '\\${m[0]}',
      );
      final rule = '/$escaped';
      if (!text.split(RegExp(r'\r?\n')).contains(rule)) {
        final newline = text.contains('\r\n') ? '\r\n' : '\n';
        final addition =
            '${text.isEmpty || text.endsWith('\n') ? '' : newline}$rule$newline';
        if (doc != null) {
          doc.editor.select(text.length, text.length);
          doc.editor.replaceSelection(addition);
          if (!await documents.save(doc)) {
            throw GitException('Save .gitignore to apply the ignore rule');
          }
        } else {
          await store.writeText('.gitignore', '$text$addition');
        }
      }
      await refreshExplorer();
    } finally {
      gitBusy = false;
      changed(persist: false);
    }
  }

  String? gitPath(Uri uri) {
    final root = workspaceRoot;
    if (root == null || !uri.toString().startsWith(root.toString())) {
      return null;
    }
    final path = Uri.decodeComponent(
      uri.toString().substring(root.toString().length),
    );
    return path.isEmpty ? null : path;
  }

  Future<FileChangeReview> reviewFile(Uri uri) async {
    final provider = git;
    final path = gitPath(uri);
    if (provider is! GitFileChangesProvider || path == null) {
      throw GitException('File is outside a supported Git project');
    }
    final document = documents.documents.where((d) => d.uri == uri).firstOrNull;
    final revision = document?.editor.revision;
    final unsaved = document?.dirty == true ? document!.editor.text : null;
    final snapshot = await (provider as GitFileChangesProvider).fileSnapshot(
      workspaceRoot!,
      path,
    );
    return FileChangeReview(snapshot, document, revision, unsaved);
  }

  Future<void> discardReviewedFile(FileChangeReview review) async {
    if (gitBusy) throw GitException('Another Git operation is running');
    final doc = review.document;
    final uri = review.snapshot.directory.resolve(
      Uri(path: review.snapshot.path).toString(),
    );
    final currentDoc = documents.documents
        .where((d) => d.uri == uri)
        .firstOrNull;
    if (currentDoc != doc) {
      throw GitException(
        'The open editor changed after review. Refresh and try again.',
      );
    }
    if (workspaceRoot != review.snapshot.directory ||
        (doc != null &&
            (doc.editor.revision != review.revision ||
                !documents.documents.contains(doc)))) {
      throw GitException(
        'The project or editor changed after review. Refresh and try again.',
      );
    }
    gitBusy = true;
    changed(persist: false);
    try {
      await (git as GitFileChangesProvider).discardFile(review.snapshot);
      if (doc != null) {
        String? text;
        try {
          text = gitText(review.snapshot.original);
        } on FormatException {
          text = null;
        }
        if (text == null) {
          await documents.close(doc);
        } else {
          doc.editor.reloadFromDisk(text);
          doc.savedText = doc.editor.text;
        }
      }
      await refreshExplorer();
      await persistNow();
    } finally {
      gitBusy = false;
      changed(persist: false);
    }
  }
}
