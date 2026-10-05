import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/platform/native_site_view.dart';

void main() {
  testWidgets(
    'Native focus keeps preview visible and stable; geometry changes still sync',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final calls = <MethodCall>[];
      const channel = MethodChannel('dev.tamtoot/site_preview');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      Widget preview(double width) => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: width,
            height: 300,
            child: const NativeSiteView(url: 'http://localhost:8080'),
          ),
        ),
      );
      await tester.pumpWidget(preview(400));
      await tester.pump(const Duration(milliseconds: 100));
      final initial = calls.where((call) => call.method == 'bounds').length;
      expect(initial, 1);
      tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.inactive,
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(calls.where((call) => call.method == 'bounds').length, initial);
      await tester.pumpWidget(preview(400));
      await tester.pump(const Duration(milliseconds: 200));
      expect(calls.where((call) => call.method == 'create').length, 1);
      expect(calls.where((call) => call.method == 'bounds').length, initial);
      await tester.pumpWidget(preview(500));
      await tester.pump(const Duration(milliseconds: 100));
      expect((calls.last.arguments as Map)['width'], 500);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      expect((calls.last.arguments as Map)['visible'], false);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect((calls.last.arguments as Map)['visible'], true);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(calls.last.method, 'dispose');
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
