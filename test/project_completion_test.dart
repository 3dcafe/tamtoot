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
