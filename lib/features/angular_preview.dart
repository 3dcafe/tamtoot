import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../platform/native_site_view.dart';
import 'package:http/http.dart' as http;
import '../core/projects/project_detection.dart';

class AngularPreview extends StatefulWidget {
  const AngularPreview({super.key, required this.target, required this.editor});
  final LaunchTarget? target;
  final Widget editor;
  @override
  State<AngularPreview> createState() => _AngularPreviewState();
}

class _AngularPreviewState extends State<AngularPreview> {
  final address = TextEditingController();
  final client = http.Client();
  Timer? timer;
  bool pinned = false, available = false, probing = false;
  String? loadedUrl;
  int generation = 0, reload = 0;
  double width = 440;
  bool get supported => !kIsWeb;
  bool get angular => widget.target?.kind == ProjectKind.angular;

  @override
  void initState() {
    super.initState();
    reset();
  }

  @override
  void didUpdateWidget(AngularPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.target?.id != widget.target?.id) reset();
  }

  void reset() {
    generation++;
    timer?.cancel();
    pinned = false;
    available = false;
    probing = false;
    loadedUrl = null;
    address.text = 'http://localhost:${widget.target?.previewPort ?? 4200}';
    if (angular && supported) {
      timer = Timer.periodic(const Duration(seconds: 5), (_) => probe());
      unawaited(probe());
    }
  }

  Uri? localUrl() {
    final uri = Uri.tryParse(address.text.trim());
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    return uri;
  }

  Future<void> probe() async {
    if (probing || !angular || !supported) return;
    final revision = generation;
    final url = localUrl();
    probing = true;
    bool reachable = false;
    if (url != null) {
      try {
        final response = await client
            .get(url)
            .timeout(const Duration(seconds: 2));
        reachable =
            response.statusCode >= 200 &&
            response.statusCode < 400 &&
            (response.headers['content-type'] ?? '').contains('text/html');
      } catch (_) {
        /* Server may not have started yet. */
      }
    }
    if (!mounted || revision != generation) return;
    setState(() {
      probing = false;
      available = reachable && url == localUrl();
      if (pinned && available && loadedUrl == null) loadedUrl = url.toString();
    });
  }

  @override
  void dispose() {
    generation++;
    timer?.cancel();
    client.close();
    address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!angular || !supported) return widget.editor;
    if (!pinned) {
      return Column(
        children: [
          Expanded(child: widget.editor),
          Material(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      available
                          ? 'Angular · local server is available'
                          : 'Angular · waiting for a local server',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.web, size: 16),
                    label: const Text('Pin preview'),
                    onPressed: () => setState(() {
                      pinned = true;
                      loadedUrl = available ? localUrl()?.toString() : null;
                    }),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final previewWidth = width.clamp(
          180.0,
          (constraints.maxWidth - 234).clamp(180.0, double.infinity),
        );
        final panel = Column(
          children: [
            Row(
              children: [
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: address,
                    style: const TextStyle(fontSize: 12),
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: 'http://localhost:4200',
                    ),
                    onSubmitted: (_) {
                      setState(() {
                        loadedUrl = localUrl()?.toString();
                        reload++;
                      });
                      unawaited(probe());
                    },
                  ),
                ),
                IconButton(
                  tooltip: 'Load / reload preview',
                  icon: const Icon(Icons.refresh, size: 18),
                  onPressed: () {
                    setState(() {
                      loadedUrl = localUrl()?.toString();
                      reload++;
                    });
                    unawaited(probe());
                  },
                ),
                IconButton(
                  tooltip: 'Close preview',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => setState(() => pinned = false),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.all(4),
              child: Text(
                available
                    ? 'Local server available · live preview'
                    : 'Server unavailable · check the address and port',
                style: const TextStyle(fontSize: 11),
              ),
            ),
            Expanded(
              child: loadedUrl == null
                  ? Center(
                      child: TextButton(
                        onPressed: () {
                          setState(() {
                            loadedUrl = localUrl()?.toString();
                            reload++;
                          });
                          unawaited(probe());
                        },
                        child: const Text('Open local preview'),
                      ),
                    )
                  : NativeSiteView(
                      key: ValueKey('$loadedUrl:$reload'),
                      url: loadedUrl!,
                    ),
            ),
          ],
        );
        if (constraints.maxWidth < 560) {
          return Column(
            children: [
              Expanded(child: widget.editor),
              Expanded(child: panel),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: widget.editor),
            MouseRegion(
              cursor: SystemMouseCursors.resizeLeftRight,
              child: Tooltip(
                message: 'Drag to resize preview',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragUpdate: (event) => setState(
                    () => width = (previewWidth - event.delta.dx).clamp(
                      180.0,
                      constraints.maxWidth - 234,
                    ),
                  ),
                  onDoubleTap: () =>
                      setState(() => width = constraints.maxWidth / 2 - 7),
                  child: Container(
                    width: 14,
                    color: Theme.of(context).colorScheme.surfaceContainerLow,
                    child: Center(
                      child: Icon(
                        Icons.drag_indicator,
                        size: 14,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(width: previewWidth, child: panel),
          ],
        );
      },
    );
  }
}
