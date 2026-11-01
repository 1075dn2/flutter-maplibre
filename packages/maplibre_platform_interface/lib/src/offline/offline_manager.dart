import 'package:maplibre_platform_interface/maplibre_platform_interface.dart';

/// Use the offline manager to download map regions for offline usage.
///
/// The [OfflineManager] cannot be used on web.
///
/// {@category Offline}
abstract interface class OfflineManager {
  /// Create a new [OfflineManager].
  ///
  /// You'll have to call [dispose] to free resources once no longer needed.
  static Future<OfflineManager> createInstance() async =>
      MapLibrePlatform.instance.createOfflineManager();

  /// Whether the offline manager is supported on the current platform.
  static bool get isSupported =>
      MapLibrePlatform.instance.offlineManagerIsSupported;

  /// Call to free resources when the [OfflineManager] is no longer needed.
  void dispose();

  /// Merge offline regions from a secondary database into the main offline
  /// database.
  Future<List<OfflineRegion>> mergeOfflineRegions({required String path});

  /// Retrieve given region in the offline database.
  Future<OfflineRegion> getOfflineRegion({required int regionId});

  /// Queries a fresh native snapshot, including after an application restart.
  /// An unknown region or failed query throws; neither implies completion.
  Future<OfflineRegionStatus> getOfflineRegionStatus({required int regionId});

  /// Suspends a region and confirms that the native SDK reports it inactive.
  /// Already queued network requests may finish. Downloaded resources remain.
  /// Callers must verify their own metadata/ownership before calling this API.
  Future<void> suspendOfflineRegion({required int regionId});

  /// Suspends, then removes an existing region from the native database.
  /// This is separate from stream cancellation, which never deletes a region.
  /// Callers must verify ownership first. Unknown regions and failures throw.
  Future<void> deleteOfflineRegion({required int regionId});

  /// Sets the maximum number of Mapbox tiles that may be downloaded and stored on
  /// the current device. This does not bound arbitrary non-Mapbox providers.
  /// By default, the limit is set to 6,000.
  void setOfflineTileCountLimit({required int amount});

  /// Set the maximum size of the ambient cache in bytes.
  Future<void> setMaximumAmbientCacheSize({required int bytes});

  /// Erase resources from the ambient cache, freeing storage space.
  Future<void> clearAmbientCache();

  /// Forces re-validation of the ambient cache.
  Future<void> invalidateAmbientCache();

  /// Retrieve all regions in the offline database.
  Future<List<OfflineRegion>> listOfflineRegions();

  /// Packs the existing database file into a minimal amount of disk space.
  ///
  /// Only available on Android.
  Future<void> packDatabase();

  /// Delete existing database and re-initialize.
  Future<void> resetDatabase();

  /// Sets whether database file packing occurs automatically.
  /// By default, the automatic database file packing is enabled.
  ///
  /// Only available on Android.
  void runPackDatabaseAutomatically({required bool enabled});

  /// Downloads a map region when the returned stream is listened to.
  ///
  /// Awaiting the subscription's cancellation suspends the native download and
  /// confirms inactivity, even when canceled before region creation completes.
  /// It does not delete partial or completed regions. Cancellation failures are
  /// reported through the returned cancellation future, not treated as success.
  /// Applications should await cancellation before disposing this manager.
  Stream<DownloadProgress> downloadRegion({
    required String mapStyleUrl,
    required LngLatBounds bounds,
    required double minZoom,
    required double maxZoom,
    required double pixelDensity,
    Map<String, Object?> metadata = const {},
  });
}
