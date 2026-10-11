import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/completion/project_completion.dart';

import 'explorer_test.dart' show RepositoryMemory;

class _CompletionMemory extends RepositoryMemory {
  @override
  Future<bool> exists(String path) async =>
      data.containsKey(path) ||
      data.keys.any((item) => item.startsWith('$path/'));
}

void main() {
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
