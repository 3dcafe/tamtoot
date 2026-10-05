import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// System browser engines, hosted by TamToot's platform runners.
class NativeSiteView extends StatefulWidget {
  const NativeSiteView({super.key, required this.url});
  final String url;
  @override
  State<NativeSiteView> createState() => _NativeSiteViewState();
}

class _NativeSiteViewState extends State<NativeSiteView>
    with WidgetsBindingObserver {
  static int nextId = 0;
  final id = nextId++;
  static const channel = MethodChannel('dev.tamtoot/site_preview');
  final area = GlobalKey();
  Timer? timer;
  bool ready = false, syncing = false, foreground = true;
  String? error;
  Map<String, Object>? _lastBounds;
  bool get overlay =>
      !kIsWeb &&
      {
        TargetPlatform.windows,
        TargetPlatform.linux,
      }.contains(defaultTargetPlatform);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (overlay) unawaited(create());
  }

  Future<void> create() async {
    try {
      await channel.invokeMethod<void>('create', {'id': id, 'url': widget.url});
      if (!mounted) {
        await channel.invokeMethod<void>('dispose', {'id': id});
        return;
      }
      ready = true;
      timer = Timer.periodic(const Duration(milliseconds: 100), (_) => sync());
      await sync();
    } catch (_) {
      unawaited(
        channel
            .invokeMethod<void>('dispose', {'id': id})
            .catchError((Object _) {}),
      );
      if (mounted) {
        setState(
          () => error = defaultTargetPlatform == TargetPlatform.windows
              ? 'Preview unavailable. Install Microsoft Edge WebView2 Runtime and reopen the preview.'
              : 'Preview unavailable. Install WebKitGTK 4.1 and rebuild TamToot.',
        );
      }
    }
  }

  Future<void> sync() async {
    if (!ready || syncing || !mounted) return;
    final box = area.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final point = box.localToGlobal(Offset.zero);
    final visible = foreground && (ModalRoute.of(context)?.isCurrent ?? true);
    final bounds = <String, Object>{
      'id': id,
      'x': point.dx,
      'y': point.dy,
      'width': box.size.width,
      'height': box.size.height,
      'scale': MediaQuery.devicePixelRatioOf(context),
      'visible': visible,
    };
    if (mapEquals(bounds, _lastBounds)) return;
    syncing = true;
    try {
      await channel.invokeMethod<void>('bounds', bounds);
      _lastBounds = bounds;
    } catch (_) {
      /* The runner may already be closing. */
    }
    syncing = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Native browser focus can make Flutter inactive without hiding the app.
    // Hiding the focused WebView here creates a hide/show loop and loses input.
    if (state == AppLifecycleState.inactive) return;
    foreground = state == AppLifecycleState.resumed;
    unawaited(sync());
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (overlay && ready) {
      unawaited(
        channel
            .invokeMethod<void>('dispose', {'id': id})
            .catchError((Object _) {}),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const codec = StandardMessageCodec();
    final params = {'url': widget.url};
    if (kIsWeb) {
      return const Center(
        child: Text('Native preview is unavailable in the browser.'),
      );
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.macOS:
        return AppKitView(
          viewType: 'dev.tamtoot/local_preview',
          creationParams: params,
          creationParamsCodec: codec,
        );
      case TargetPlatform.iOS:
        return UiKitView(
          viewType: 'dev.tamtoot/local_preview',
          creationParams: params,
          creationParamsCodec: codec,
        );
      case TargetPlatform.android:
        return AndroidView(
          viewType: 'dev.tamtoot/local_preview',
          creationParams: params,
          creationParamsCodec: codec,
        );
      default:
        return SizedBox.expand(
          key: area,
          child: Center(child: Text(error ?? 'Loading preview…')),
        );
    }
  }
}
