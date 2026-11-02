import 'dart:async';
import 'dart:io';

import 'package:maplibre_platform_interface/maplibre_platform_interface.dart';

/// Seeds exact local resources before pack creation. Insertion is not Ready;
/// only native pack completion establishes that resources were consumed.
Future<void> seedLocalOfflineStyle({
  required String styleUrl,
  required Future<void> Function(List<int> bytes) seed,
  BundledGlyphSeeds? bundledGlyphSeeds,
  Future<void> Function(String url, List<int> bytes)? seedGlyph,
  bool Function()? isCanceled,
  Duration preparationTimeout = const Duration(seconds: 20),
}) async {
  final uri = Uri.parse(styleUrl);
  if (bundledGlyphSeeds != null &&
      (uri.scheme != 'file' || seedGlyph == null)) {
    throw const FormatException('Bundled glyphs require a local style and seed writer.');
  }
  if (uri.scheme != 'file') return;
  final clock = Stopwatch()..start();
  Duration remaining() {
    if (isCanceled?.call() ?? false) throw StateError('Download canceled.');
    final left = preparationTimeout - clock.elapsed;
    if (left <= Duration.zero) {
      throw TimeoutException('Offline resource preparation timed out.');
    }
    return left;
  }

  final bytes = await File.fromUri(uri).readAsBytes().timeout(remaining());
  if (bytes.isEmpty) {
    throw const FormatException('The local offline map style is empty.');
  }
  remaining();
  bundledGlyphSeeds?.validateStyleBytes(bytes);
  if (bundledGlyphSeeds != null) {
    for (final entry in bundledGlyphSeeds.resources.entries) {
      final timeout = remaining();
      // Serial preloads bound outstanding callbacks to one. A timed-out native
      // callback remains retained by the manager; no later seed/pack is queued.
      await seedGlyph!(entry.key, entry.value).timeout(timeout);
    }
  }
  final timeout = remaining();
  await seed(bytes).timeout(timeout);
  remaining();
}
