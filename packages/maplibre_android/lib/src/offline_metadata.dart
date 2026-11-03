import 'dart:convert';

/// Decodes opaque SDK metadata without adopting foreign/invalid region data.
/// Java bytes are signed; normalize them before decoding UTF-8 (e.g. Hebrew).
Map<String, Object?> decodeOfflineMetadata(Iterable<int> bytes) {
  try {
    final decoded = jsonDecode(
      utf8.decode(bytes.map((byte) => byte & 0xff).toList()),
    );
    if (decoded is Map<String, dynamic>) return decoded;
  } on FormatException {
    // Foreign metadata is valid at the SDK level but is not owned JSON data.
  }
  return const {};
}
