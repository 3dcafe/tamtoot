import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/editor/document/editor_controller.dart';
import 'package:tamtoot/core/completion/project_completion.dart';

import 'explorer_test.dart' show RepositoryMemory;

class _CompletionMemory extends RepositoryMemory {
  @override
  Future<bool> exists(String path) async =>
      data.containsKey(path) ||
      data.keys.any((item) => item.startsWith('$path/'));
}

void main() {
  test('Flutter values use argument type and replace qualified prefixes', () {
    const header = "import 'package:flutter/material.dart';\n";
    List<CompletionSymbol> hints(String text) =>
        ProjectCompletionIndex.dartArgumentSuggestions(
          source: text,
          offset: text.length,
        ) ??
        [];
    final alignment = hints(
      '${header}Row(mainAxisAlignment: MainAxisAlignment.ce',
    ).single;
    expect(alignment.insertText, 'MainAxisAlignment.center');
    expect(alignment.replacementLength, 'MainAxisAlignment.ce'.length);
    expect(
      hints('${header}Container(padding: Ed').map((s) => s.insertText),
      contains('const EdgeInsets.all(8)'),
    );
    expect(
      hints('${header}Container(color: Colors.blu').single.insertText,
      'Colors.blue',
    );
    expect(
      hints('${header}Text(textAlign: ').map((s) => s.name),
      contains('TextAlign.center'),
    );
    expect(hints('${header}Text(softWrap: f').single.insertText, 'false');
    expect(hints('${header}Container(width: Colors.'), isEmpty);
    expect(hints('Container(color: Colors.'), isEmpty);
    expect(
      hints(
        "import 'package:flutter/material.dart' as f;\nContainer(color: Colors.blu",
      ),
      isEmpty,
    );
    expect(
      hints('${header}Row(mainAxisAlignment: ce').single.insertText,
      'MainAxisAlignment.center',
    );
    expect(
      hints(
        "import 'package:flutter/widgets.dart';\nContainer(color: Colors.blu",
      ),
      isEmpty,
    );
    expect(hints('$header// Container(color: Colors.blu'), isEmpty);
    expect(hints('${header}Container(color: compute(Colors.blu'), isEmpty);
  });

  test(
    'Dart multiline functions and constructors include nested callback parameters',
    () async {
      final store = _CompletionMemory();
      await store.writeText('model.dart', """
class Model {
  /// Creates the model.
  const Model({
    required this.title,
    this.count = 0,
  });
  factory Model.named({
    required String title,
  }) => Model(title: title);
  final String title;
  final int count;
}
/// Sends data.
Future<void> send<T>(
  T data, {
  required Map<String, int> headers, // Request metadata.
  void Function(int, String)? onDone,
  /* displayed label */ String label = 'a,b',
}) async {}
""");
      final index = ProjectCompletionIndex(store);
      await index.initialize();
      List<CompletionSymbol> hints(String text) =>
          index.suggest(source: text, offset: text.length, language: 'dart');
      expect(hints('Model(ti').single.insertText, 'title: ');
      expect(hints('Model.named(ti').single.insertText, 'title: ');
      expect(
        hints('send<String>(data, he').single.signature,
        'required Map<String, int> headers',
      );
      expect(
        hints('send(data, on').single.signature,
        'void Function(int, String)? onDone',
      );
      expect(hints('send(data, la').single.insertText, 'label: ');
      final constructor = hints('Mod').firstWhere((s) => s.name == 'Model');
      expect(constructor.documentation, 'Creates the model.');
      expect(hints('send').first.documentation, 'Sends data.');
    },
  );
  test(
    'Dart incremental multiline signatures converge after edits and Undo',
    () async {
      final editor = EditorController(
        'void send({\n  required String title,\n  int count = 0,\n}) {}\n${List.generate(1000, (i) => 'final value$i = $i;').join('\n')}\nsend(ti',
      );
      addTearDown(editor.dispose);
      final index = ProjectCompletionIndex(_CompletionMemory());
      await index.initialize();
      List<String> query({bool incremental = true}) => index
          .suggest(
            source: editor.text,
            offset: editor.text.length,
            language: 'dart',
            document: incremental ? editor : null,
          )
          .map((s) => s.signature)
          .toList();
      expect(query().single, 'required String title');
      var count = index.activeLinesParsed;
      final position = editor.text.indexOf('String title');
      editor.select(position, position + 6);
      editor.replaceSelection('int');
      final incremental = query();
      expect(incremental.single, 'required int title');
      expect(index.activeLinesParsed - count, lessThan(6));
      expect(incremental, query(incremental: false));
      query();
      editor.undo();
      expect(query().single, 'required String title');
    },
  );

  test(
    'Dart named arguments filter prefix and omit supplied arguments',
    () async {
      final store = _CompletionMemory();
      await store.writeText(
        'api.dart',
        'void greet({required String title, int count = 0}) {}',
      );
      final index = ProjectCompletionIndex(store);
      await index.initialize();
      List<CompletionSymbol> hints(String source) => index.suggest(
        source: source,
        offset: source.length,
        language: 'dart',
      );
      expect(hints('greet(ti').single.insertText, 'title: ');
      expect(hints('greet(title: "x", co').single.insertText, 'count: ');
      expect(hints('greet(title: "x", ti'), isEmpty);
      expect(
        hints('greet(title: ti').where((s) => s.insertText == 'title: '),
        isEmpty,
      );
      expect(
        hints('greet(').map((s) => s.name),
        containsAll(['title', 'count']),
      );
    },
  );
  test('Flutter argument hints require an import and handle nested values', () {
    final index = ProjectCompletionIndex(_CompletionMemory());
    List<CompletionSymbol> hints(String source) =>
        index.suggest(source: source, offset: source.length, language: 'dart');
    const header = "import 'package:flutter/material.dart';\n";
    expect(
      hints(
        '${header}Container(child: Foo(width: 1, padding: 2), pa',
      ).single.name,
      'padding',
    );
    expect(hints('${header}unknown('), isEmpty);
    expect(hints('Container(pa'), isEmpty);
    expect(hints('${header}Container(pa').single.insertText, 'padding: ');
    expect(
      hints('${header}Container(child: Text("a,b"), pa').single.name,
      'padding',
    );
    expect(hints('${header}Container(child: Text("a"), ch'), isEmpty);
    expect(
      hints(
        '${header}Padding(',
      ).firstWhere((s) => s.name == 'padding').signature,
      contains('required'),
    );
    expect(hints('$header// Container(pa'), isEmpty);
  });
  test('Explicit completion works without an identifier prefix', () {
    final index = ProjectCompletionIndex(_CompletionMemory());
    const source = 'void run() {}\n';
    expect(
      index.suggest(source: source, offset: source.length, language: 'dart'),
      isEmpty,
    );
    expect(
      index
          .suggest(
            source: source,
            offset: source.length,
            language: 'dart',
            explicit: true,
          )
          .map((s) => s.name),
      contains('run'),
    );
  });

  test(
    'PHP indexes methods, properties and dollar-prefixed parameters',
    () async {
      final store = _CompletionMemory();
      await store.writeText('Service.php', r'''<?php
class Service {
  public string $title = "demo";
  public function render(int $count): string {}
}
''');
      final index = ProjectCompletionIndex(store);
      await index.initialize();
      const source = r'$service = new Service(); $service?->';
      final result = index.suggest(
        source: source,
        offset: source.length,
        language: 'php',
      );
      expect(result.map((item) => item.name), containsAll(['title', 'render']));
      const local = r'function run(int $count) { $cou';
      expect(
        index
            .suggest(source: local, offset: local.length, language: 'php')
            .single
            .name,
        r'$count',
      );
    },
  );
  test(
    'React detection gates JS and TS templates and resets after removal',
    () async {
      final store = _CompletionMemory();
      final react = ProjectCompletionIndex(store);
      await react.initialize();
      List<CompletionSymbol> suggestions(String language) =>
          react.suggest(source: 'rcstate', offset: 7, language: language);
      expect(suggestions('typescript'), isEmpty);
      await store.writeText(
        'package.json',
        '{"devDependencies":{"react":"^19.0.0"}}',
      );
      await react.refresh();
      expect(react.reactDetected, isTrue);
      expect(react.angularDetected, isFalse);
      for (final language in ['javascript', 'typescript']) {
        expect(suggestions(language).single.insertText, contains('useState'));
      }
      expect(suggestions('php'), isEmpty);
      await store.writeText(
        'package.json',
        '{"dependencies":{"react-dom":"*"}}',
      );
      await react.refresh();
      expect(react.reactDetected, isFalse);
      expect(suggestions('javascript'), isEmpty);
      await store.writeText('package.json', '{invalid');
      await react.refresh();
      expect(react.reactDetected, isFalse);
    },
  );
  test(
    'TypeScript indexes typed members, parameters and generic functions',
    () async {
      final store = _CompletionMemory();
      await store.writeText(
        'service.ts',
        'export class Service {\n  readonly title: string = "Demo";\n  render<T>(count: number): T {}\n}',
      );
      final index = ProjectCompletionIndex(store);
      await index.initialize();
      const source = 'const service: Service = new Service();\nservice?.';
      final members = index.suggest(
        source: source,
        offset: source.length,
        language: 'typescript',
      );
      expect(
        members.map((item) => item.name),
        containsAll(['title', 'render']),
      );
      expect(
        members.firstWhere((item) => item.name == 'render').signature,
        'render<T>(count: number)',
      );
      const local = 'export function run(count: number) {\n cou';
      expect(
        index
            .suggest(
              source: local,
              offset: local.length,
              language: 'typescript',
            )
            .single
            .signature,
        'count: number',
      );
    },
  );
  test(
    'Angular templates require valid root manifests and clear after removal',
    () async {
      final store = _CompletionMemory();
      final index = ProjectCompletionIndex(store);
      await index.initialize();
      List<CompletionSymbol> templates(String language, String prefix) => index
          .suggest(source: prefix, offset: prefix.length, language: language);
      expect(templates('typescript', 'ngcomponent'), isEmpty);
      await store.writeText(
        'package.json',
        '{"dependencies":{"@angular/core":"^20.0.0"}}',
      );
      await index.refresh();
      expect(index.angularDetected, isTrue);
      expect(
        templates('typescript', 'ngcomponent').single.insertText,
        contains('@Component'),
      );
      expect(templates('html', 'ngfor').single.insertText, contains('@for'));
      expect(templates('java', 'ngcomponent'), isEmpty);
      await store.writeText('package.json', '{"name":"ordinary-project"}');
      await index.refresh();
      expect(index.angularDetected, isFalse);
      expect(templates('typescript', 'ngcomponent'), isEmpty);
      await store.writeText('angular.json', '{invalid');
      await index.refresh();
      expect(index.angularDetected, isFalse);
      await store.writeText('angular.json', '{"projects":{"app":{}}}');
      await index.refresh();
      expect(index.angularDetected, isTrue);
    },
  );
  test(
    'indexes Java and Kotlin project members, parameters and nullable receivers',
    () async {
      final store = _CompletionMemory();
      await store.writeText(
        'Service.java',
        'class Service {\n  public String title;\n  public String render(int count) {}\n}',
      );
      await store.writeText(
        'Service.kt',
        'class Service {\n  val title: String = "demo"\n  fun <T> render(count: Int): T {}\n}',
      );
      final index = ProjectCompletionIndex(store);
      await index.initialize();
      for (final language in ['java', 'kotlin']) {
        final source = language == 'java'
            ? 'Service service = new Service();\nservice.'
            : 'val service: Service? = null\nservice?.';
        final result = index.suggest(
          source: source,
          offset: source.length,
          language: language,
        );
        expect(
          result.map((item) => item.name),
          containsAll(['title', 'render']),
        );
        expect(result.every((item) => item.language == language), isTrue);
      }
      const source = 'fun run(count: Int) {\n  cou';
      final parameters = index.suggest(
        source: source,
        offset: source.length,
        language: 'kotlin',
      );
      expect(parameters.single.signature, 'count: Int');
    },
  );
  test(
    'snippets are prefix filtered and never appear in member access',
    () async {
      final index = ProjectCompletionIndex(_CompletionMemory());
      await index.initialize();
      const snippets = {
        'prop': {
          'prefix': 'prop',
          'body': 'public int Count { get; set; }',
          'description': 'Auto-property',
        },
      };
      final result = index.suggest(
        source: 'pr',
        offset: 2,
        language: 'csharp',
        snippets: snippets,
      );
      expect(result.single.kind, CompletionKind.snippet);
      expect(result.single.insertText, contains('Count'));
      expect(result.single.documentation, 'Auto-property');
      expect(
        index.suggest(
          source: 'item.pr',
          offset: 7,
          language: 'csharp',
          snippets: snippets,
        ),
        isEmpty,
      );
    },
  );
  test(
    'nullable receivers find generic methods on records and structs',
    () async {
      final index = ProjectCompletionIndex(_CompletionMemory());
      await index.initialize();
      const source =
          'public record struct Service\n{\n  public T Convert<T>(T value) {}\n}\nService? service;\nservice?.Con';
      final result = index.suggest(
        source: source,
        offset: source.length,
        language: 'csharp',
      );
      expect(result.single.name, 'Convert');
      expect(result.single.owner, 'Service');
      expect(result.single.signature, 'Convert<T>(T value)');
    },
  );
  test(
    'suggests local variables, fields, properties, constants and methods',
    () async {
      final index = ProjectCompletionIndex(_CompletionMemory());
      await index.initialize();
      const source = '''
class Car {
  /// Human-readable model.
  final String model;
  static const int maxSpeed = 240;
  int wheels = 4;
  String get label => model;
  void drive(int distance) {}

  void run(int laps) {
    Car car = Car();
    car.
    ca
    dis
  }
}
''';
      List<CompletionSymbol> at(String marker) => index.suggest(
        source: source,
        offset: source.indexOf(marker) + marker.length,
        language: 'dart',
        limit: 30,
      );
      final members = at('car.');
      expect(
        members.map((item) => item.name),
        containsAll(['model', 'maxSpeed', 'wheels', 'label', 'drive']),
      );
      expect(
        members.firstWhere((item) => item.name == 'model').documentation,
        contains('Human-readable'),
      );
      expect(
        members.firstWhere((item) => item.name == 'drive').callable,
        isTrue,
      );
      expect(
        members.firstWhere((item) => item.name == 'label').kind,
        CompletionKind.property,
      );
      expect(at('\n    ca').map((item) => item.name), contains('car'));
      expect(at('\n    dis').map((item) => item.name), contains('distance'));
    },
  );

  test(
    'constructor inference prioritizes matching owner with Allman braces',
    () async {
      final store = _CompletionMemory();
      await store.writeText('services.cs', '''
class Other
{
  public void AFirst() {}
}
class PaymentService
{
  public void ZPayment() {}
}
''');
      final index = ProjectCompletionIndex(store);
      await index.initialize();
      const source = 'var service = new PaymentService(); service.';
      final items = index.suggest(
        source: source,
        offset: source.length,
        language: 'csharp',
      );
      expect(items.first.name, 'ZPayment');
      expect(items.first.owner, 'PaymentService');
    },
  );

  test('does not suggest generated or dependency methods', () async {
    final store = _CompletionMemory();
    for (final folder in ['node_modules', 'build', '.dart_tool', 'obj']) {
      await store.writeText('$folder/file.dart', 'void generatedMethod() {}');
    }
    await store.writeText('lib/file.dart', 'void userMethod() {}');
    final index = ProjectCompletionIndex(store);
    await index.initialize();
    final items = index.suggest(
      source: 'service.',
      offset: 8,
      language: 'dart',
    );
    expect(items.map((item) => item.name), ['userMethod']);
  });

  test(
    'indexes C# methods, receiver types and documentation comments',
    () async {
      final store = _CompletionMemory();
      await store.writeText('Services/Payments.cs', '''
class PaymentService {
  /// Returns the payment method selected for this order.
  public string GetPaymentMethod(int orderId) {
    return "card";
  }

  // Cancels an existing payment.
  public void CancelPayment(string id) {}
}
''');
      final index = ProjectCompletionIndex(store);
      await index.initialize();
      const source = '''
class Checkout {
  void Run() {
    PaymentService payment = new PaymentService();
    payment.
  }
}
''';
      final suggestions = index.suggest(
        source: source,
        offset: source.indexOf('payment.') + 'payment.'.length,
        language: 'csharp',
      );
      expect(
        suggestions.map((item) => item.name),
        contains('GetPaymentMethod'),
      );
      final method = suggestions.firstWhere(
        (item) => item.name == 'GetPaymentMethod',
      );
      expect(method.owner, 'PaymentService');
      expect(method.signature, 'GetPaymentMethod(int orderId)');
      expect(method.documentation, contains('selected for this order'));
      expect(await store.exists(ProjectCompletionIndex.cachePath), isTrue);
    },
  );

  test(
    'indexes Dart comments and refreshes only changed project content',
    () async {
      final store = _CompletionMemory();
      await store.writeText('lib/payments.dart', '''
class PaymentService {
  /// Loads the current payment method.
  String getPaymentMethod(int orderId) => 'card';
}
''');
      final index = ProjectCompletionIndex(store);
      await index.initialize();
      const source = '''
void run() {
  final payment = PaymentService();
  payment.getP
}
''';
      var suggestions = index.suggest(
        source: source,
        offset: source.indexOf('payment.getP') + 'payment.getP'.length,
        language: 'dart',
      );
      expect(suggestions.single.name, 'getPaymentMethod');
      expect(suggestions.single.documentation, contains('Loads the current'));

      await store.writeText('lib/payments.dart', '''
class PaymentService {
  /// Refunds a completed payment.
  Future<void> refundPayment(String id) async {}
}
''');
      await index.refresh();
      const changed = 'PaymentService payment = PaymentService(); payment.ref';
      suggestions = index.suggest(
        source: changed,
        offset: changed.length,
        language: 'dart',
      );
      expect(suggestions.map((item) => item.name), contains('refundPayment'));
      expect(
        suggestions.map((item) => item.name),
        isNot(contains('getPaymentMethod')),
      );
    },
  );

  test(
    'uses unsaved active document methods without waiting for disk indexing',
    () async {
      final index = ProjectCompletionIndex(_CompletionMemory());
      await index.initialize();
      const source = '''
class LocalService {
  // Only exists in the unsaved editor.
  void calculateTotal(int count) {}
}
void run() {
  final service = LocalService();
  service.cal
}
''';
      final suggestions = index.suggest(
        source: source,
        offset: source.indexOf('service.cal') + 'service.cal'.length,
        language: 'dart',
      );
      expect(suggestions.single.name, 'calculateTotal');
      expect(suggestions.single.documentation, contains('unsaved editor'));
    },
  );
}
