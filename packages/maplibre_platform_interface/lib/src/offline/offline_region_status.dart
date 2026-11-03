import 'package:maplibre_platform_interface/maplibre_platform_interface.dart';

/// A fresh native SDK snapshot of an existing offline region.
///
/// Completion means the SDK reports all required resources downloaded with a
/// precise resource count. It is not cryptographic verification, a guarantee
/// against eviction, or a promise that rendering will make no network requests.
class OfflineRegionStatus extends DownloadProgress {
  /// Creates a native region status snapshot.
  const OfflineRegionStatus({
    required super.loadedBytes,
    required super.loadedTiles,
    required super.totalTilesEstimated,
    required super.totalTiles,
    required super.region,
    required super.downloadCompleted,
    required this.isActive,
  });

  /// Whether the native SDK currently considers this region actively downloading.
  final bool isActive;

  @override
  bool operator ==(Object other) =>
      super == other &&
      other is OfflineRegionStatus &&
      isActive == other.isActive;

  @override
  int get hashCode => Object.hash(super.hashCode, isActive);

  @override
  String toString() =>
      'OfflineRegionStatus(isActive: $isActive, ${super.toString()})';
}
