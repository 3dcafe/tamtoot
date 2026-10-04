import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../app/ide_session.dart';
import '../editor/widgets/code_editor.dart';
import '../core/filesystem/filesystem.dart';
import '../workspace/documents/document_service.dart';

class MarkdownDocumentView extends StatefulWidget {
  const MarkdownDocumentView({
    super.key,
    required this.document,
    required this.session,
  });
  final OpenDocument document;
  final IdeSession session;
  @override
  State<MarkdownDocumentView> createState() => _MarkdownDocumentViewState();
}

class _MarkdownDocumentViewState extends State<MarkdownDocumentView> {
  StreamSubscription<void>? _subscription;
  late String source = widget.document.editor.text;
  final images = <Uri, Future<Uint8List>>{};
  @override
  void initState() {
    super.initState();
    _subscription = widget.document.editor.changes.listen((_) {
      final text = widget.document.editor.text;
      if (mounted && source != text) setState(() => source = text);
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  Widget image(Uri uri, String? title, String? alt) {
    final resolved = widget.document.uri?.resolveUri(uri) ?? uri;
    final svg = resolved.path.toLowerCase().endsWith('.svg');
    Widget failure() => Text(
      alt?.isNotEmpty == true ? alt! : 'Image unavailable',
      style: TextStyle(color: Theme.of(context).colorScheme.error),
    );
    if (resolved.scheme == 'https' || resolved.scheme == 'http') {
      return svg
          ? SvgPicture.network(
              resolved.toString(),
              placeholderBuilder: (_) => Text(alt ?? 'Loading image…'),
              errorBuilder: (_, _, _) => failure(),
            )
          : Image.network(
              resolved.toString(),
              errorBuilder: (_, _, _) => failure(),
            );
    }
    if (widget.document.uri == null && !uri.hasScheme) return failure();
    return FutureBuilder<Uint8List>(
      future: images.putIfAbsent(
        resolved,
        () => widget.session.documents.files.readBytes(resolved),
      ),
      builder: (context, snapshot) {
        if (snapshot.hasError) return failure();
        final bytes = snapshot.data;
        if (bytes == null) return Text(alt ?? 'Loading image…');
        return svg
            ? SvgPicture.memory(bytes, errorBuilder: (_, _, _) => failure())
            : Image.memory(bytes, errorBuilder: (_, _, _) => failure());
      },
    );
  }

  Future<void> link(String text, String? href, String title) async {
    if (href == null) return;
    final uri = Uri.tryParse(href);
    if (uri == null) return;
    if (!uri.hasScheme && uri.path.isNotEmpty && widget.document.uri != null) {
      final resolved = widget.document.uri!.resolveUri(
        uri.replace(fragment: ''),
      );
      try {
        await widget.session.run(
          'file.openEntry',
          FileEntry(resolved, Uri.decodeComponent(resolved.pathSegments.last)),
        );
      } catch (e) {
        widget.session.log('Markdown link: $e', error: true);
      }
    } else {
      await Clipboard.setData(ClipboardData(text: href));
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Link copied')));
      }
    }
  }

  Widget pane(String title, Widget content) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        color: Color(widget.session.theme.color('panel')),
        child: Text(
          title,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
      Expanded(child: content),
    ],
  );
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final editor = pane(
        'Markdown',
        CodeEditor(
          key: ValueKey('editor-${widget.document.id}'),
          controller: widget.document.editor,
          session: widget.session,
          language: widget.session.languages.forPath(widget.document.name),
        ),
      );
      final preview = pane(
        'Preview',
        ColoredBox(
          color: Color(widget.session.theme.color('editor')),
          child: Markdown(
            data: source,
            selectable: true,
            padding: const EdgeInsets.all(20),
            imageBuilder: image,
            onTapLink: link,
            styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                .copyWith(
                  p: TextStyle(
                    fontSize: 14,
                    height: 1.5,
                    color: Color(widget.session.theme.color('foreground')),
                  ),
                  code: TextStyle(
                    fontFamily:
                        widget.session.settings.get('fontFamily') as String,
                    fontSize: 12,
                    color: Color(widget.session.theme.color('foreground')),
                  ),
                ),
          ),
        ),
      );
      if (constraints.maxWidth < 640) {
        return Column(
          children: [
            Expanded(child: editor),
            const Divider(height: 1),
            Expanded(child: preview),
          ],
        );
      }
      return Row(
        children: [
          Expanded(child: editor),
          const VerticalDivider(width: 1),
          Expanded(child: preview),
        ],
      );
    },
  );
}
