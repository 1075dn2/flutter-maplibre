import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre/maplibre.dart';
// ignore: implementation_imports
import 'package:maplibre_android/src/offline_style_seed.dart';
// ignore: implementation_imports
import 'package:maplibre_ios/src/offline_style_seed.dart';

void main() {
  const root = 'file:///private/app/map-fonts/varela-v1-'
      '${BundledGlyphSeeds.manifestSha256}/';
  const template = '$root{fontstack}/{range}.pbf';
  late Map<String, List<int>> resources;
  late Directory directory;
  late File style;
  BundledGlyphSeeds make() => BundledGlyphSeeds.varelaV1(
    glyphTemplate: template, resources: resources,
  );
  setUp(() async {
    final fixture = jsonDecode(utf8.decode(gzip.decode(
      File('test/fixtures/varela-v1/resources.json.gz').readAsBytesSync(),
    ))) as Map<String, dynamic>;
    resources = {
      for (final entry in fixture.entries)
        Uri.parse(root).resolveUri(Uri(path: entry.key)).toString():
          base64Decode(entry.value as String).toList(),
    };
    directory = await Directory.systemTemp.createTemp('bundled-glyph-test-');
    style = File('${directory.path}/style.json');
    await style.writeAsString(jsonEncode({'version': 8, 'glyphs': template}));
  });
  tearDown(() => directory.delete(recursive: true));

  test('exact pin accepts all 512 resources and makes deep immutable copies', () {
    final bundle = make();
    expect(bundle.resources.length, 512);
    final key = resources.keys.first;
    resources[key]![0] ^= 1;
    expect(bundle.resources[key]![0], isNot(resources[key]![0]));
    expect(() => bundle.resources.clear(), throwsUnsupportedError);
    expect(() => bundle.resources[key]![0] = 0, throwsUnsupportedError);
  });
  test('rejects missing, corrupted, oversized and foreign URL resources', () {
    final key = resources.keys.first;
    final original = resources[key]!;
    resources.remove(key);
    expect(make, throwsFormatException);
    resources[key] = [...original]..[0] ^= 1;
    expect(make, throwsFormatException);
    resources[key] = List.filled(BundledGlyphSeeds.maxResourceBytes + 1, 0);
    expect(make, throwsFormatException);
    resources.remove(key);
    resources['https://example.invalid/font.pbf'] = original;
    expect(make, throwsFormatException);
  });
  test('rejects unsupported local paths and remote hosts', () {
    for (final invalid in [
      template.replaceFirst('file:///', 'https://example.invalid/'),
      template.replaceFirst('/private/app/', '/private/%2e%2e/'),
      template.replaceFirst('/map-fonts/', '/other/'),
      template.replaceFirst('/private/app/', '/private/%2fapp/'),
      template.replaceFirst('file:///', 'file://localhost/'),
      '$template?query=yes',
    ]) {
      expect(() => BundledGlyphSeeds.varelaV1(
        glyphTemplate: invalid, resources: resources,
      ), throwsFormatException);
    }
  });
  test('Android orders glyphs, style, then creation; completion is not invented', () async {
    final order = <String>[];
    final created = Completer<int>();
    final enqueued = Completer<void>();
    final result = createWithOfflineStyleSeed<int>(
      mapStyleUrl: style.uri.toString(), bundledGlyphSeeds: make(),
      seedGlyph: (url, bytes) => order.add(url),
      seed: (_) => order.add('style'),
      create: () { order.add('create'); enqueued.complete(); return created.future; },
    );
    await enqueued.future;
    expect(order.length, 514);
    expect(order.sublist(512), ['style', 'create']);
    created.complete(7);
    expect(await result, 7);
  });
  test('mismatched style fails before any insertion', () async {
    await style.writeAsString('{"glyphs":"https://example.invalid"}');
    await expectLater(createWithOfflineStyleSeed<int>(
      mapStyleUrl: style.uri.toString(), bundledGlyphSeeds: make(),
      seedGlyph: (_, __) => fail('No glyph insertion'),
      seed: (_) => fail('No style insertion'),
      create: () async => fail('No creation'),
    ), throwsFormatException);
  });
  test('iOS cancellation stops further preloads and style insertion', () async {
    var canceled = false;
    var count = 0;
    await expectLater(seedLocalOfflineStyle(
      styleUrl: style.uri.toString(), bundledGlyphSeeds: make(),
      isCanceled: () => canceled,
      seedGlyph: (_, __) async { count++; canceled = true; },
      seed: (_) async => fail('No style insertion'),
    ), throwsStateError);
    expect(count, 1);
  });
  test('iOS timeout never starts later seeds even if callback completes late', () async {
    final native = Completer<void>();
    var count = 0;
    await expectLater(seedLocalOfflineStyle(
      styleUrl: style.uri.toString(), bundledGlyphSeeds: make(),
      preparationTimeout: const Duration(milliseconds: 50),
      seedGlyph: (_, __) { count++; return native.future; },
      seed: (_) async => fail('No style insertion'),
    ), throwsA(isA<TimeoutException>()));
    native.complete();
    await Future<void>.delayed(Duration.zero);
    expect(count, 1);
  });
  test('Android cancellation and seed errors prevent creation', () async {
    var count = 0;
    await expectLater(createWithOfflineStyleSeed<int>(
      mapStyleUrl: style.uri.toString(), bundledGlyphSeeds: make(),
      isCanceled: () => count == 1,
      seedGlyph: (_, __) => count++,
      seed: (_) => fail('No style insertion'),
      create: () async => fail('No creation'),
    ), throwsStateError);
    expect(count, 1);
    await expectLater(createWithOfflineStyleSeed<int>(
      mapStyleUrl: style.uri.toString(), bundledGlyphSeeds: make(),
      seedGlyph: (_, __) => throw StateError('Native seed failed'),
      seed: (_) => fail('No style insertion'),
      create: () async => fail('No creation'),
    ), throwsStateError);
  });
  test('glyph seeds cannot accompany a remote style', () async {
    await expectLater(createWithOfflineStyleSeed<int>(
      mapStyleUrl: 'https://example.invalid/style.json',
      bundledGlyphSeeds: make(), seedGlyph: (_, __) => fail('No insertion'),
      seed: (_) => fail('No insertion'), create: () async => fail('No creation'),
    ), throwsFormatException);
    await expectLater(seedLocalOfflineStyle(
      styleUrl: 'https://example.invalid/style.json',
      bundledGlyphSeeds: make(), seedGlyph: (_, __) async => fail('No insertion'),
      seed: (_) async => fail('No insertion'),
    ), throwsFormatException);
  });
  test('iOS awaits every glyph callback before inserting style', () async {
    var count = 0;
    var styleCount = 0;
    await seedLocalOfflineStyle(
      styleUrl: style.uri.toString(), bundledGlyphSeeds: make(),
      seedGlyph: (_, __) async {
        await Future<void>.delayed(Duration.zero);
        count++;
      },
      seed: (_) async { expect(count, 512); styleCount++; },
    );
    expect(styleCount, 1);
  });
  test('iOS native glyph failure prevents later inserts', () async {
    var count = 0;
    await expectLater(seedLocalOfflineStyle(
      styleUrl: style.uri.toString(), bundledGlyphSeeds: make(),
      seedGlyph: (_, __) async { count++; throw StateError('Native seed failed'); },
      seed: (_) async => fail('No style insertion'),
    ), throwsStateError);
    expect(count, 1);
  });

}
