import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_ios/src/offline_style_seed.dart';

void main() {
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('ios-seed-'));
  tearDown(() async => root.delete(recursive: true));

  test('preserves exact local bytes and escaped URL', () async {
    final file = File('${root.path}/map Hebrew א.json');
    final bytes = [123, 34, 195, 169, 34, 58, 49, 125];
    await file.writeAsBytes(bytes);
    List<int>? actual;
    await seedLocalOfflineStyle(
      styleUrl: file.uri.toString(),
      seed: (value) async {
        actual = value;
      },
    );
    expect(actual, bytes);
  });
  test('awaits native completion before caller can create pack', () async {
    final file = await File('${root.path}/style.json').writeAsString('{}');
    final callback = Completer<void>();
    final called = Completer<void>();
    var created = false;
    final future = seedLocalOfflineStyle(
      styleUrl: file.uri.toString(),
      seed: (_) {
        called.complete();
        return callback.future;
      },
    ).then((_) => created = true);
    await called.future;
    expect(created, isFalse);
    callback.complete();
    await future;
    expect(created, isTrue);
  });
  test('remote styles never seed', () async {
    var calls = 0;
    await seedLocalOfflineStyle(
      styleUrl: 'https://example.com/style.json',
      seed: (_) async {
        calls++;
      },
    );
    expect(calls, 0);
  });
  test('missing local style fails before native work', () async {
    var calls = 0;
    await expectLater(
      seedLocalOfflineStyle(
        styleUrl: File('${root.path}/missing').uri.toString(),
        seed: (_) async {
          calls++;
        },
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(calls, 0);
  });
  test('empty style fails before native work', () async {
    final file = await File('${root.path}/empty').writeAsString('');
    var calls = 0;
    await expectLater(
      seedLocalOfflineStyle(
        styleUrl: file.uri.toString(),
        seed: (_) async {
          calls++;
        },
      ),
      throwsFormatException,
    );
    expect(calls, 0);
  });
  test('native seed failure prevents pack creation', () async {
    final file = await File('${root.path}/style.json').writeAsString('{}');
    var created = false;
    await expectLater(
      seedLocalOfflineStyle(
        styleUrl: file.uri.toString(),
        seed: (_) async {
          throw StateError('failed');
        },
      ).then((_) => created = true),
      throwsStateError,
    );
    expect(created, isFalse);
  });
}
