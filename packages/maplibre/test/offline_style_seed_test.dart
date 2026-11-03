import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// Exercises production file preparation without JNI or provider networking.
// ignore: implementation_imports
import 'package:maplibre_android/src/offline_style_seed.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('offline-style-seed-');
  });
  tearDown(() => directory.delete(recursive: true));

  test(
    'reads exact local bytes before creating and waits for callback',
    () async {
      final file = File('${directory.path}/מפה style.json');
      final bytes = utf8.encode('{"version":8,"name":"מפה","sources":{}}');
      await file.writeAsBytes(bytes, flush: true);
      final order = <String>[];
      final creation = Completer<int>();
      final enqueued = Completer<void>();
      var completed = false;
      final result =
          createWithOfflineStyleSeed(
            mapStyleUrl: file.uri.toString(),
            seed: (actual) {
              expect(actual, bytes);
              order.add('seed');
            },
            create: () {
              order.add('create');
              enqueued.complete();
              return creation.future;
            },
          ).then((value) {
            completed = true;
            return value;
          });
      await enqueued.future;
      expect(order, ['seed', 'create']);
      expect(completed, isFalse);
      creation.complete(42);
      expect(await result, 42);
    },
  );

  test('remote style is not read or seeded', () async {
    expect(
      await createWithOfflineStyleSeed(
        mapStyleUrl: 'https://example.invalid/style.json',
        seed: (_) => fail('Remote styles must use the native network path'),
        create: () async => 7,
      ),
      7,
    );
  });

  test('missing local file fails before native side effects', () async {
    await expectLater(
      createWithOfflineStyleSeed<int>(
        mapStyleUrl: File('${directory.path}/missing.json').uri.toString(),
        seed: (_) => fail('Missing bytes cannot be seeded'),
        create: () async => fail('Missing file cannot create a region'),
      ),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('empty local style fails before native side effects', () async {
    final file = await File('${directory.path}/empty.json').create();
    await expectLater(
      createWithOfflineStyleSeed<int>(
        mapStyleUrl: file.uri.toString(),
        seed: (_) => fail('Empty bytes cannot be seeded'),
        create: () async => fail('Empty style cannot create a region'),
      ),
      throwsFormatException,
    );
  });

  test('synchronous seed error prevents creation', () async {
    final file = await File('${directory.path}/style.json').writeAsString('{}');
    final failure = StateError('native seed call failed');
    await expectLater(
      createWithOfflineStyleSeed<int>(
        mapStyleUrl: file.uri.toString(),
        seed: (_) => throw failure,
        create: () async => fail('Failed seed call cannot create a region'),
      ),
      throwsA(same(failure)),
    );
  });

  test('creation callback error is not mistaken for seed success', () async {
    final file = await File('${directory.path}/style.json').writeAsString('{}');
    final failure = StateError('database creation failed');
    await expectLater(
      createWithOfflineStyleSeed<int>(
        mapStyleUrl: file.uri.toString(),
        seed: (_) {},
        create: () => Future<int>.error(failure),
      ),
      throwsA(same(failure)),
    );
  });
}
