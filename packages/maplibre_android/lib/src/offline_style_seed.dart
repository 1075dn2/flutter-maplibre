import 'dart:io';

import 'package:maplibre_platform_interface/maplibre_platform_interface.dart';

/// Seeds a local style before enqueueing native region creation.
///
/// Android's offline downloader reads its database, then its network file
/// source, not the renderer's local-file loader. Seed the exact file URL in the
/// database so existing region identity and renderer reopening stay unchanged.
/// Remote styles retain their normal native download path.
///
/// [seed] must enqueue the write synchronously on the same native database actor
/// as [create]. The awaited creation callback then orders activation after the
/// write. It does not acknowledge successful persistence: Android's seed API
/// reports no database write errors. Only native resource progress is evidence
/// that the style was consumed. This helper itself never activates a region.
Future<T> createWithOfflineStyleSeed<T>({
  required String mapStyleUrl,
  required void Function(List<int> bytes) seed,
  required Future<T> Function() create,
  BundledGlyphSeeds? bundledGlyphSeeds,
  void Function(String url, List<int> bytes)? seedGlyph,
  bool Function()? isCanceled,
}) async {
  final uri = Uri.parse(mapStyleUrl);
  if (bundledGlyphSeeds != null &&
      (uri.scheme != 'file' || seedGlyph == null)) {
    throw const FormatException('Bundled glyphs require a local style and seed writer.');
  }
  if (isCanceled?.call() ?? false) throw StateError('Download canceled.');
  if (uri.scheme == 'file') {
    final bytes = await File.fromUri(uri).readAsBytes();
    if (bytes.isEmpty) {
      throw const FormatException('The local offline map style is empty.');
    }
    if (isCanceled?.call() ?? false) throw StateError('Download canceled.');
    bundledGlyphSeeds?.validateStyleBytes(bytes);
    if (bundledGlyphSeeds != null) {
      for (final entry in bundledGlyphSeeds.resources.entries) {
        if (isCanceled?.call() ?? false) throw StateError('Download canceled.');
        seedGlyph!(entry.key, entry.value);
      }
    }
    seed(bytes);
  }
  return create();
}
