import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:tamtoot/core/git/git_service.dart';
import 'package:tamtoot/core/git/git_pack.dart';
import 'package:tamtoot/core/git/git_objects.dart';
import 'package:tamtoot/core/git/git_unpack_async.dart';
import 'package:tamtoot/platform/git_shared.dart';

class StreamingClient extends http.BaseClient {
  StreamingClient(this.stream, this.length);
  final Stream<List<int>> stream;
  final int? length;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(stream, 200, contentLength: length);
}

void main() {
  test(
    'Background unpack preserves object contents and reports corrupt packs',
    () async {
      final object = GitObject(
        GitObjectType.blob,
        Uint8List.fromList([1, 2, 3]),
      );
      final pack = buildPackfile([object], sharedDeflate);
      final unpacked = await unpackGitPackAsync(pack, sharedInflateAt);
      expect(unpacked.single.data, object.content);
      await expectLater(
        unpackGitPackAsync([0, 1], sharedInflateAt),
        throwsFormatException,
      );
    },
  );
  for (final total in <int?>[6, null]) {
    test('Download reports bytes before completion (total: $total)', () async {
      final stream = StreamController<List<int>>();
      final client = StreamingClient(stream.stream, total);
      addTearDown(client.close);
      final transport = PackageHttpTransport(client: client);
      final progress = <GitProgress>[];
      transport.onTransferProgress = progress.add;
      var finished = false;
      final response = transport
          .send(
            method: 'POST',
            url: Uri.parse('https://example.com/repo.git/git-upload-pack'),
          )
          .then((response) {
            finished = true;
            return response;
          });
      await Future<void>.delayed(const Duration(milliseconds: 120));
      stream.add(Uint8List.fromList([1, 2, 3]));
      await Future<void>.delayed(Duration.zero);
      expect(finished, false);
      expect(progress.last.completed, 3);
      expect(progress.last.total, total);
      expect(progress.last.fraction, total == null ? isNull : 0.5);
      stream.add([4, 5, 6]);
      await stream.close();
      expect((await response).body, [1, 2, 3, 4, 5, 6]);
      expect(progress.last.completed, 6);
      expect(progress.last.fraction, total == null ? isNull : 1.0);
    });
  }

  test(
    'Interrupted download preserves last received count and propagates failure',
    () async {
      final stream = StreamController<List<int>>();
      final transport = PackageHttpTransport(
        client: StreamingClient(stream.stream, null),
      );
      final progress = <GitProgress>[];
      transport.onTransferProgress = progress.add;
      final response = transport.send(
        method: 'GET',
        url: Uri.parse('https://example.com/repo.git'),
      );
      final failure = expectLater(response, throwsStateError);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      stream.add([1, 2]);
      await Future<void>.delayed(Duration.zero);
      stream.addError(StateError('connection interrupted'));
      await stream.close();
      await failure;
      expect(progress.last.completed, 2);
    },
  );
}
