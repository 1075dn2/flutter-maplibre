import 'dart:io';

/// Seeds exact local style bytes under their original URL before pack creation.
/// Remote styles retain the native HTTP path. Completion orders the DB work;
/// it is not proof of persistence. Only native pack completion establishes Ready.
Future<void> seedLocalOfflineStyle({
  required String styleUrl,
  required Future<void> Function(List<int> bytes) seed,
}) async {
  final uri = Uri.parse(styleUrl);
  if (uri.scheme != 'file') return;
  final bytes = await File.fromUri(uri).readAsBytes();
  if (bytes.isEmpty) {
    throw const FormatException('The local offline map style is empty.');
  }
  await seed(bytes);
}
