import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'ide_session.dart';

final sessionProvider = Provider<IdeSession>(
  (ref) => throw StateError('Bootstrap session override required'),
);
final sessionChangesProvider = StreamProvider<int>(
  (ref) => ref.watch(sessionProvider).changes,
);
