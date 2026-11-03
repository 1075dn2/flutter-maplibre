import 'dart:convert';

/// Reads this adapter's JSON context without adopting arbitrary foreign packs.
///
/// Other SDK consumers may store arbitrary bytes or non-object JSON contexts.
/// Returning an empty map gives those packs no ID in this adapter's namespace.
Map<String, Object?> decodeOfflinePackContext(List<int> bytes) {
  try {
    final decoded = jsonDecode(utf8.decode(bytes));
    return decoded is Map<String, dynamic> ? decoded : const {};
  } on FormatException {
    return const {};
  }
}
