import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_ios/src/offline_context.dart';

void main() {
  test('round-trips UTF-8 ownership metadata without corrupting Hebrew', () {
    final context = <String, Object?>{
      'id': 42,
      'metadata': <String, Object?>{'title': 'מפה', 'language': 'he'},
    };
    expect(decodeOfflinePackContext(utf8.encode(jsonEncode(context))), context);
  });

  test('foreign malformed, binary and non-object contexts are not adopted', () {
    for (final bytes in <List<int>>[
      [],
      [255, 254],
      utf8.encode('not JSON'),
      utf8.encode('[]'),
      utf8.encode('null'),
      utf8.encode('17'),
      utf8.encode('"external region"'),
    ]) {
      expect(decodeOfflinePackContext(bytes), isEmpty);
    }
  });
}
