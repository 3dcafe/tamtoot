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
