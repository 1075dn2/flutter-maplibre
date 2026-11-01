import 'dart:async';
import 'dart:convert';

import 'package:jni/jni.dart';
import 'package:maplibre_android/src/extensions.dart';
import 'package:maplibre_android/src/functions.dart';
import 'package:maplibre_android/src/jni.g.dart' as jni;
import 'package:maplibre_android/src/offline_region_download.dart';
import 'package:maplibre_android/src/offline_style_seed.dart';
import 'package:maplibre_platform_interface/maplibre_platform_interface.dart';

/// MapLibre Android specific implementation of the [OfflineManager].
class OfflineManagerAndroid implements OfflineManager {
  OfflineManagerAndroid._(this._jManager);

  final jni.OfflineManager _jManager;
  final _downloads = <OfflineRegionDownload>{};
  final _regionTasks = <int, Future<void>>{};
  var _disposed = false;
  var _released = false;
  var _pending = 0;

  /// Create a new [OfflineManager].
  static Future<OfflineManager> createInstance() async => using((arena) {
    final context = getJContext()..releasedBy(arena);
    jni.MapLibre.getInstance(context).releasedBy(arena);
    return OfflineManagerAndroid._(jni.OfflineManager.getInstance(context));
  });

  void _checkOpen() {
    if (_disposed) throw StateError('Offline manager has been disposed');
  }

  // Each asynchronous JNI operation owns its arena until the native callback
  // completes. Never put a callback into a synchronous, short-lived arena.
  Future<T> _run<T>(Future<T> Function(Arena arena) action) async {
    _checkOpen();
    _pending++;
    try {
      return await using(action);
    } finally {
      _pending--;
      _releaseIfIdle();
    }
  }

  Future<T> _forRegion<T>(int id, Future<T> Function() action) =>
      _forRegionRetained(id, action).timeout(const Duration(seconds: 30));

  // A timeout is not native cancellation. The underlying task still owns its
  // lock, manager and JNI references until its callback really arrives.
  Future<T> _forRegionRetained<T>(int id, Future<T> Function() action) async {
    _checkOpen();
    final previous = _regionTasks[id];
    final done = Completer<void>();
    _regionTasks[id] = done.future;
    try {
      if (previous != null) await previous;
      _checkOpen();
      return await action();
    } finally {
      done.complete();
      if (identical(_regionTasks[id], done.future)) _regionTasks.remove(id);
    }
  }

  void _releaseIfIdle() {
    if (_disposed && !_released && _pending == 0 && _downloads.isEmpty) {
      _released = true;
      _jManager.release();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final download in _downloads.toList()) {
      // dispose is a legacy void API. Explicitly await subscription.cancel()
      // first when the caller needs confirmation of native inactivity.
      unawaited(download.cancel().catchError(download.reportError));
    }
    _releaseIfIdle();
  }

  Future<jni.OfflineRegion> _lookup(int id, Arena arena) {
    final result = Completer<jni.OfflineRegion>();
    final callback = jni.OfflineManager$GetOfflineRegionCallback.implement(
      jni.$OfflineManager$GetOfflineRegionCallback(
        onRegion: (region) {
          if (result.isCompleted) {
            region.release();
          } else {
            region.releasedBy(arena);
            result.complete(region);
          }
        },
        onRegionNotFound: () =>
            _completeError(result, StateError('Offline region $id not found')),
        onError: (error) => _completeError(result, _nativeError(error)),
        onRegion$async: true,
        onRegionNotFound$async: true,
        onError$async: true,
      ),
    )..releasedBy(arena);
    _jManager.getOfflineRegion(id, callback);
    return result.future;
  }

  @override
  Future<OfflineRegion> getOfflineRegion({required int regionId}) => _forRegion(
    regionId,
    () => _run((arena) async {
      final region = await _lookup(regionId, arena);
      return region.toOfflineRegion();
    }),
  );

  @override
  Future<OfflineRegionStatus> getOfflineRegionStatus({required int regionId}) =>
      _forRegion(
        regionId,
        () => _run((arena) async {
          final region = await _lookup(regionId, arena);
          return _readStatus(region);
        }),
      );

  Future<void> _suspend(int id, Arena arena) async {
    // Use the exact Java handle which activated the region: the SDK tracks
    // activation on each OfflineRegion object, not just its database ID.
    for (final download in _downloads.toList()) {
      if (download.regionId == id) await download.cancel();
    }
    final region = await _lookup(id, arena);
    await _suspendNative(region);
  }

  @override
  Future<void> suspendOfflineRegion({required int regionId}) =>
      _forRegion(regionId, () => _run((arena) => _suspend(regionId, arena)));

  @override
  Future<void> deleteOfflineRegion({required int regionId}) => _forRegion(
    regionId,
    () => _run((arena) async {
      await _suspend(regionId, arena);
      final region = await _lookup(regionId, arena);
      final result = Completer<void>();
      final callback = jni.OfflineRegion$OfflineRegionDeleteCallback.implement(
        jni.$OfflineRegion$OfflineRegionDeleteCallback(
          onDelete: () {
            if (!result.isCompleted) result.complete();
          },
          onError: (error) => _completeError(result, _nativeError(error)),
          onDelete$async: true,
          onError$async: true,
        ),
      )..releasedBy(arena);
      region.delete(callback);
      await result.future;
    }),
  );

  @override
  Future<List<OfflineRegion>> listOfflineRegions() => _run((arena) {
    final result = Completer<List<OfflineRegion>>();
    final callback = jni.OfflineManager$ListOfflineRegionsCallback.implement(
      jni.$OfflineManager$ListOfflineRegionsCallback(
        onList: (regions) => _completeRegions(result, regions),
        onError: (error) => _completeError(result, _nativeError(error)),
        onList$async: true,
        onError$async: true,
      ),
    )..releasedBy(arena);
    _jManager.listOfflineRegions(callback);
    return result.future;
  });

  @override
  Future<List<OfflineRegion>> mergeOfflineRegions({required String path}) =>
      _run((arena) {
        final result = Completer<List<OfflineRegion>>();
        final callback =
            jni.OfflineManager$MergeOfflineRegionsCallback.implement(
              jni.$OfflineManager$MergeOfflineRegionsCallback(
                onMerge: (regions) => _completeRegions(result, regions),
                onError: (error) => _completeError(result, _nativeError(error)),
                onMerge$async: true,
                onError$async: true,
              ),
            )..releasedBy(arena);
        _jManager.mergeOfflineRegions(
          path.toJString()..releasedBy(arena),
          callback,
        );
        return result.future;
      });

  Future<void> _fileSource(
    void Function(jni.OfflineManager$FileSourceCallback) action,
  ) => _run((arena) {
    final result = Completer<void>();
    final callback = jni.OfflineManager$FileSourceCallback.implement(
      jni.$OfflineManager$FileSourceCallback(
        onSuccess: () {
          if (!result.isCompleted) result.complete();
        },
        onError: (error) => _completeError(result, _nativeError(error)),
        onSuccess$async: true,
        onError$async: true,
      ),
    )..releasedBy(arena);
    action(callback);
    return result.future;
  });

  @override
  void setOfflineTileCountLimit({required int amount}) {
    _checkOpen();
    _jManager.setOfflineMapboxTileCountLimit(amount);
  }

  @override
  Future<void> setMaximumAmbientCacheSize({required int bytes}) => _fileSource(
    (callback) => _jManager.setMaximumAmbientCacheSize(bytes, callback),
  );

  @override
  Future<void> clearAmbientCache() => _fileSource(_jManager.clearAmbientCache);

  @override
  Future<void> invalidateAmbientCache() =>
      _fileSource(_jManager.invalidateAmbientCache);

  @override
  Future<void> packDatabase() => _fileSource(_jManager.packDatabase);

  @override
  Future<void> resetDatabase() {
    _checkOpen();
    if (_downloads.isNotEmpty || _regionTasks.isNotEmpty) {
      throw StateError('Cannot reset the database during region operations');
    }
    return _fileSource(_jManager.resetDatabase);
  }

  @override
  void runPackDatabaseAutomatically({required bool enabled}) {
    _checkOpen();
    _jManager.runPackDatabaseAutomatically(enabled);
  }

  @override
  Stream<DownloadProgress> downloadRegion({
    required String mapStyleUrl,
    required LngLatBounds bounds,
    required double minZoom,
    required double maxZoom,
    required double pixelDensity,
    Map<String, Object?> metadata = const {},
  }) {
    _checkOpen();
    // Encode now, so invalid metadata fails without creating a native region.
    final metadataBytes = utf8.encode(jsonEncode(metadata));
    late final OfflineRegionDownload download;
    download = OfflineRegionDownload(
      onStart: () {
        _checkOpen();
        _downloads.add(download);
      },
      onFinish: () {
        _downloads.remove(download);
        _releaseIfIdle();
      },
      create: () => createWithOfflineStyleSeed(
        mapStyleUrl: mapStyleUrl,
        seed: (bytes) => using((arena) {
          _jManager.putResourceWithUrl(
            mapStyleUrl.toJString()..releasedBy(arena),
            JByteArray.from(bytes)..releasedBy(arena),
            0,
            0,
            null,
            false,
          );
        }),
        // Android 12.3.1 queues put and create on the same FIFO database
        // actor. The onCreate callback is our write-completion barrier before
        // activation, not a guarantee the cache write succeeded. Real native
        // progress remains required; putResourceWithUrl has no error callback.
        create: () => _AndroidDownloadHandle.create((arena, callback) {
          final definition = jni.OfflineTilePyramidRegionDefinition(
            mapStyleUrl.toJString()..releasedBy(arena),
            bounds.toJLatLngBounds(arena: arena),
            minZoom,
            maxZoom,
            pixelDensity,
          )..releasedBy(arena);
          _jManager.createOfflineRegion(
            definition.as(jni.OfflineRegionDefinition.type)..releasedBy(arena),
            JByteArray.from(metadataBytes)..releasedBy(arena),
            callback,
          );
        }),
      ),
    );
    return download.stream;
  }
}

Exception _nativeError(JString? error) => Exception(
  error?.toDartString(releaseOriginal: true) ?? 'Unknown native offline error',
);

void _completeError<T>(Completer<T> result, Object error) {
  if (!result.isCompleted) result.completeError(error);
}

void _completeRegions(
  Completer<List<OfflineRegion>> result,
  JArray<jni.OfflineRegion>? regions,
) {
  try {
    final values = using((arena) {
      if (regions == null) return <OfflineRegion>[];
      regions.releasedBy(arena);
      return List.generate(regions.length, (index) {
        final region = regions[index]..releasedBy(arena);
        return region.toOfflineRegion();
      });
    });
    if (!result.isCompleted) result.complete(values);
  } catch (error) {
    _completeError(result, error);
  }
}

OfflineRegionStatus _status(
  jni.OfflineRegionStatus status,
  OfflineRegion region,
) => OfflineRegionStatus(
  loadedBytes: status.getCompletedResourceSize(),
  loadedTiles: status.getCompletedResourceCount(),
  totalTiles: status.getRequiredResourceCount(),
  totalTilesEstimated: !status.isRequiredResourceCountPrecise(),
  region: region,
  downloadCompleted:
      status.isComplete() && status.isRequiredResourceCountPrecise(),
  isActive: status.getDownloadState() == jni.OfflineRegion.STATE_ACTIVE,
);

Future<OfflineRegionStatus> _readStatus(jni.OfflineRegion region) => using((
  arena,
) {
  final result = Completer<OfflineRegionStatus>();
  final value = region.toOfflineRegion();
  final callback = jni.OfflineRegion$OfflineRegionStatusCallback.implement(
    jni.$OfflineRegion$OfflineRegionStatusCallback(
      onStatus: (status) {
        try {
          if (status == null) throw StateError('Native region status is null');
          if (!result.isCompleted) result.complete(_status(status, value));
        } catch (error) {
          _completeError(result, error);
        } finally {
          status?.release();
        }
      },
      onError: (error) => _completeError(result, _nativeError(error)),
      onStatus$async: true,
      onError$async: true,
    ),
  )..releasedBy(arena);
  region.getStatus(callback);
  return result.future;
});

Future<void> _suspendNative(jni.OfflineRegion region) async {
  region.setDownloadState(jni.OfflineRegion.STATE_INACTIVE);
  final status = await _readStatus(region);
  if (status.isActive) {
    throw StateError(
      'Native offline region ${status.region.id} is still active',
    );
  }
}

/// Owns JNI references until native inactivity and observer detach are confirmed.
final class _AndroidDownloadHandle implements OfflineDownloadHandle {
  _AndroidDownloadHandle(this._arena, this._region, this.region);

  final Arena _arena;
  final jni.OfflineRegion _region;
  @override
  final OfflineRegion region;
  var _released = false;

  static Future<OfflineDownloadHandle> create(
    void Function(Arena, jni.OfflineManager$CreateOfflineRegionCallback) action,
  ) async {
    final arena = Arena();
    final result = Completer<jni.OfflineRegion>();
    try {
      final callback = jni.OfflineManager$CreateOfflineRegionCallback.implement(
        jni.$OfflineManager$CreateOfflineRegionCallback(
          onCreate: (region) {
            if (result.isCompleted) {
              region.release();
            } else {
              region.releasedBy(arena);
              result.complete(region);
            }
          },
          onError: (error) => _completeError(result, _nativeError(error)),
          onCreate$async: true,
          onError$async: true,
        ),
      )..releasedBy(arena);
      action(arena, callback);
      final region = await result.future;
      return _AndroidDownloadHandle(arena, region, region.toOfflineRegion());
    } catch (_) {
      // Failed creation never activates a download. Its one-shot callback has
      // completed; incoming arguments of duplicate/late callbacks are released.
      arena.releaseAll();
      rethrow;
    }
  }

  @override
  void observe(
    void Function(DownloadProgress) progress,
    void Function(Object) error,
  ) {
    final observer = jni.OfflineRegion$OfflineRegionObserver.implement(
      jni.$OfflineRegion$OfflineRegionObserver(
        onStatusChanged: (status) {
          try {
            if (!_released) progress(_status(status, region));
          } catch (exception) {
            if (!_released) error(exception);
          } finally {
            status.release();
          }
        },
        onError: (nativeError) {
          try {
            if (!_released) {
              error(
                Exception(
                  nativeError.getMessage().toDartString(releaseOriginal: true),
                ),
              );
            }
          } finally {
            nativeError.release();
          }
        },
        mapboxTileCountLimitExceeded: (limit) {
          if (!_released)
            error(StateError('Tile count limit exceeded: $limit'));
        },
        onStatusChanged$async: true,
        onError$async: true,
        mapboxTileCountLimitExceeded$async: true,
      ),
    )..releasedBy(_arena);
    _region.setObserver(observer);
  }

  @override
  void activate() => _region.setDownloadState(jni.OfflineRegion.STATE_ACTIVE);

  @override
  Future<void> suspendAndDetach() async {
    await _suspendNative(_region);
    _region.setObserver(null);
  }

  @override
  void release() {
    if (_released) return;
    _released = true;
    _arena.releaseAll();
  }
}
