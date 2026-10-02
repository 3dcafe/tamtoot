import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../app/ide_session.dart';
import '../editor/widgets/code_editor.dart';
import '../workspace/documents/document_service.dart';

/// Android Studio-style media tab: closable like a code editor, with a
/// preview pane. SVG keeps editable source on the left.
class MediaDocumentView extends StatelessWidget {
  const MediaDocumentView({
    super.key,
    required this.document,
    required this.session,
  });

  final OpenDocument document;
  final IdeSession session;

  @override
  Widget build(BuildContext context) {
    if (document.kind == DocumentKind.image) {
      return _ImagePreview(document: document);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final stacked = constraints.maxWidth < 720;
        final editor = CodeEditor(
          key: ValueKey('editor-${document.id}'),
          controller: document.editor,
          session: session,
          language: session.languages.forPath(document.name),
        );
        final preview = _SvgPreview(source: document.editor.text);
        if (stacked) {
          return Column(
            children: [
              Expanded(flex: 3, child: editor),
              const Divider(height: 1),
              Expanded(flex: 2, child: preview),
            ],
          );
        }
        return Row(
          children: [
            Expanded(flex: 3, child: editor),
            const VerticalDivider(width: 1),
            Expanded(flex: 2, child: preview),
          ],
        );
      },
    );
  }
}

class _ImagePreview extends StatelessWidget {
  const _ImagePreview({required this.document});
  final OpenDocument document;

  @override
  Widget build(BuildContext context) {
    final bytes = document.bytes;
    final theme = Theme.of(context);
    if (bytes == null || bytes.isEmpty) {
      return Center(
        child: Text(
          'Image bytes are not loaded yet.',
          style: theme.textTheme.bodyMedium,
        ),
      );
    }
    return ColoredBox(
      color: theme.colorScheme.surfaceContainerLowest,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${document.name} · ${bytes.length} bytes · preview',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: InteractiveViewer(
              minScale: 0.25,
              maxScale: 8,
              child: Center(
                child: Image.memory(
                  bytes,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stack) => Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('Could not decode image: $error'),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SvgPreview extends StatefulWidget {
  const _SvgPreview({required this.source});
  final String source;

  @override
  State<_SvgPreview> createState() => _SvgPreviewState();
}

class _SvgPreviewState extends State<_SvgPreview> {
  String? _renderable;
  String? _hint;

  @override
  void initState() {
    super.initState();
    _sync(widget.source);
  }

  @override
  void didUpdateWidget(covariant _SvgPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) _sync(widget.source);
  }

  void _sync(String source) {
    final trimmed = source.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _renderable = null;
        _hint = 'Empty SVG';
      });
      return;
    }
    try {
      final lower = trimmed.toLowerCase();
      if (!lower.contains('<svg')) {
        throw const FormatException('Missing <svg> root.');
      }
      // Reject obviously broken markup while typing; keep the last good frame.
      if (RegExp(r'<svg\b', caseSensitive: false).firstMatch(trimmed) == null) {
        throw const FormatException('Missing <svg> root.');
      }
      setState(() {
        _renderable = trimmed;
        _hint = null;
      });
    } catch (error) {
      setState(() {
        _hint = 'Preview waits for valid SVG (${_short(error)})';
      });
    }
  }

  static String _short(Object error) {
    final text = '$error'.replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.length <= 80 ? text : '${text.substring(0, 80)}…';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.surfaceContainerLowest,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Preview',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: InteractiveViewer(
              minScale: 0.25,
              maxScale: 8,
              child: Center(
                child: _renderable == null
                    ? Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          _hint ?? 'No preview',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : SvgPicture.string(
                        _renderable!,
                        fit: BoxFit.contain,
                      ),
              ),
            ),
          ),
          if (_hint != null && _renderable != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                _hint!,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
