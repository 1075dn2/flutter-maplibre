import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;

import 'package:maplibre_ios/src/extensions.dart';
import 'package:maplibre_ios/src/maplibre_ffi.g.dart';
import 'package:maplibre_ios/src/offline_context.dart';
import 'package:maplibre_ios/src/offline_style_seed.dart';
import 'package:maplibre_platform_interface/maplibre_platform_interface.dart';
import 'package:objective_c/objective_c.dart' as objc;

/// iOS specific implementation of the [OfflineManager].
class OfflineManagerIos implements OfflineManager {
  /// Create a new iOS specific [OfflineManager] instance.
  OfflineManagerIos(this._storage) {
    Helpers.createOfflinePackProgressListenerWithCallbacks(_callbacks);
    _liveManagers.add(this);
  }

  // NotificationCenter does not own its observer. Keep this owner and its
  // callbacks alive until disposal has stopped downloads and detached observers.
  static final _liveManagers = <OfflineManagerIos>{};
  static var _lastRegionId = 0;
  final MLNOfflineStorage _storage;
  late final OfflinePackProgressCallbacks _callbacks =
      OfflinePackProgressCallbacks$Builder.implementAsListener(
        onErrorWithNotification_: _onErrorWithNotification,
        onMaximumAllowedTilesWithNotification_: _onMaximumAllowedTiles,
        onProgressChangedWithNotification_: _onProgressChanged,
      );
  final _downloads = <_IosDownload>{};
  final _statusWaiters = <int, List<Completer<OfflineRegionStatus>>>{};
  final _pendingBlocks = <Object>{};
  // removePack invalidates its handle immediately, including on failure.
  // Tombstones prevent late notifications from messaging an invalid handle.
  // Storage is a singleton. These tombstones must also survive manager
  // recreation: a failed removal leaves an invalid object in shared storage.
  // Retaining the tiny wrapper prevents address reuse until process restart.
  static final _invalidPacks = <int, MLNOfflinePack>{};
  static final _invalidRegionIds = <int>{};
  bool _disposed = false;
  bool _detached = false;

  /// Create a new [OfflineManagerIos] instance.
  static Future<OfflineManagerIos> createInstance() async =>
      OfflineManagerIos(MLNOfflineStorage.getSharedOfflineStorage());

  void _checkUsable() {
    if (_disposed) throw StateError('Offline manager is disposed');
  }

  void _checkPack(MLNOfflinePack pack) {
    if (_invalidPacks.containsKey(pack.ref.pointer.address)) {
      throw StateError('Offline pack was removed or invalidated');
    }
  }

  Future<List<MLNOfflinePack>> _loadPacks() async {
    var array = _storage.packs;
    final stopwatch = Stopwatch()..start();
    while (array == null && stopwatch.elapsed < const Duration(seconds: 5)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      array = _storage.packs;
    }
    if (array == null)
      throw TimeoutException('Loading offline packs timed out');
    return array
        .asDart()
        .map(MLNOfflinePack.as)
        .where((pack) => !_invalidPacks.containsKey(pack.ref.pointer.address))
        .toList();
  }

  Future<MLNOfflinePack> _findPack(int regionId) async {
    if (_invalidRegionIds.contains(regionId)) {
      throw StateError(
        'Region $regionId was removed or invalidated; '
        'restart the app before retrying a failed removal',
      );
    }
    if (regionId < 0) throw StateError('Offline region $regionId not found');
    final packs = await _loadPacks();
    // Another operation may have deleted a pack while loading was awaited.
    if (_invalidRegionIds.contains(regionId)) {
      throw StateError('Offline region $regionId was removed or invalidated');
    }
    for (final pack in packs) {
      if (_invalidPacks.containsKey(pack.ref.pointer.address)) continue;
      if (_PackContext.fromNSData(pack.context).id == regionId) return pack;
    }
    throw StateError('Offline region $regionId not found');
  }

  OfflineRegion _region(MLNOfflinePack pack) {
    _checkPack(pack);
    final context = _PackContext.fromNSData(pack.context);
    final region = MLNTilePyramidOfflineRegion.as(pack.region);
    return OfflineRegion(
      id: context.id,
      bounds: region.bounds.toLngLatBounds(),
      minZoom: region.minimumZoomLevel,
      maxZoom: region.maximumZoomLevel,
      pixelRatio: context.pixelDensity,
      styleUrl: context.styleUrl,
      metadata: context.metadata,
    );
  }

  OfflineRegionStatus _snapshot(MLNOfflinePack pack) {
    _checkPack(pack);
    final state = pack.state;
    if (state == MLNOfflinePackState.MLNOfflinePackStateUnknown ||
        state == MLNOfflinePackState.MLNOfflinePackStateInvalid) {
      throw StateError('Offline pack status is not known');
    }
    final progress = pack.toDownloadProgress(_region(pack));
    return OfflineRegionStatus(
      loadedBytes: progress.loadedBytes,
      loadedTiles: progress.loadedTiles,
      totalTilesEstimated: progress.totalTilesEstimated,
      totalTiles: progress.totalTiles,
      region: progress.region,
      downloadCompleted: progress.downloadCompleted,
      isActive: state == MLNOfflinePackState.MLNOfflinePackStateActive,
    );
  }

  Future<OfflineRegionStatus> _requestStatus(MLNOfflinePack pack) async {
    if (_detached) throw StateError('Offline manager observer is detached');
    _checkPack(pack);
    final address = pack.ref.pointer.address;
    final completer = Completer<OfflineRegionStatus>();
    _statusWaiters.putIfAbsent(address, () => []).add(completer);
    try {
      pack.requestProgress();
      // An unknown or timed-out result must never become an offline-ready flag.
      final status = await completer.future.timeout(
        const Duration(seconds: 10),
      );
      // A concurrent delete may invalidate the handle after a notification was
      // queued but before this continuation runs. Never return Ready for it.
      _checkPack(pack);
      return status;
    } finally {
      final waiters = _statusWaiters[address];
      waiters?.remove(completer);
      if (waiters?.isEmpty ?? false) _statusWaiters.remove(address);
      _detachIfIdle();
    }
  }

  Future<void> _suspendPack(MLNOfflinePack pack) async {
    _checkPack(pack);
    // Complete packs are preserved. No delete, resume or cache reset occurs.
    if (pack.state != MLNOfflinePackState.MLNOfflinePackStateComplete) {
      pack.suspend();
    }
    final status = await _requestStatus(pack);
    if (status.isActive) {
      throw StateError(
        'Native offline region is still active after suspension',
      );
    }
  }

  @override
  Future<OfflineRegion> getOfflineRegion({required int regionId}) async {
    _checkUsable();
    return _region(await _findPack(regionId));
  }

  @override
  Future<OfflineRegionStatus> getOfflineRegionStatus({
    required int regionId,
  }) async {
    _checkUsable();
    return _requestStatus(await _findPack(regionId));
  }

  @override
  Future<void> suspendOfflineRegion({required int regionId}) async {
    _checkUsable();
    final pack = await _findPack(regionId);
    _checkUsable();
    _checkPack(pack);
    final operations = _downloads.where((op) => op.id == regionId).toList();
    if (operations.isEmpty) {
      await _suspendPack(pack);
    } else {
      for (final operation in operations) {
        await operation.cancel();
        operation.close();
      }
    }
  }

  @override
  Future<void> deleteOfflineRegion({required int regionId}) async {
    _checkUsable();
    await suspendOfflineRegion(regionId: regionId);
    final pack = await _findPack(regionId);
    _checkUsable();
    _checkPack(pack);
    final address = pack.ref.pointer.address;
    _invalidPacks[address] = pack;
    _invalidRegionIds.add(regionId);
    final waiters = _statusWaiters.remove(address) ?? [];
    for (final waiter in waiters) {
      if (!waiter.isCompleted) {
        waiter.completeError(StateError('Offline region is being deleted'));
      }
    }
    // Never touch pack again after this call, even if deletion fails. Recovery
    // requires restarting or globally reloading storage; we cannot suspend
    // unrelated, unowned packs to perform that reload here.
    await _withCompletion(
      (block) => _storage.removePack(pack, withCompletionHandler: block),
    );
  }

  @override
  Future<List<OfflineRegion>> listOfflineRegions() async {
    _checkUsable();
    final packs = await _loadPacks();
    _checkUsable();
    return packs
        .where(
          (pack) =>
              !_invalidPacks.containsKey(pack.ref.pointer.address) &&
              _PackContext.fromNSData(pack.context).id >= 0,
        )
        .map(_region)
        .toList(growable: false);
  }

  @override
  Stream<DownloadProgress> downloadRegion({
    required String mapStyleUrl,
    required LngLatBounds bounds,
    required double minZoom,
    required double maxZoom,
    required double pixelDensity,
    Map<String, Object?> metadata = const {},
    BundledGlyphSeeds? bundledGlyphSeeds,
  }) {
    _checkUsable();
    final operation = _IosDownload(this);
    operation.controller.onListen = () {
      _downloads.add(operation);
      unawaited(
        _startDownload(
          operation,
          mapStyleUrl,
          bounds,
          minZoom,
          maxZoom,
          pixelDensity,
          metadata,
          bundledGlyphSeeds,
        ),
      );
    };
    return operation.controller.stream;
  }

  Future<void> _startDownload(
    _IosDownload operation,
    String style,
    LngLatBounds bounds,
    double minZoom,
    double maxZoom,
    double pixelDensity,
    Map<String, Object?> metadata,
    BundledGlyphSeeds? bundledGlyphSeeds,
  ) async {
    try {
      // The native offline downloader uses its database/HTTP path, not the
      // renderer's local-file loader. Preserve the original file URL identity.
      await seedLocalOfflineStyle(
        styleUrl: style,
        seed: (bytes) => _seedStyle(style, bytes),
        bundledGlyphSeeds: bundledGlyphSeeds,
        seedGlyph: _seedStyle,
        isCanceled: () => _disposed || operation.cancelRequested,
      );
      final packs = await _loadPacks();
      if (_disposed || operation.cancelRequested) {
        operation.completeCreation(null);
        operation.close();
        _downloads.remove(operation);
        _detachIfIdle();
        return;
      }
      final usedIds = packs
          .where((pack) => !_invalidPacks.containsKey(pack.ref.pointer.address))
          .map((pack) => _PackContext.fromNSData(pack.context).id)
          .where((id) => id >= 0)
          .toSet();
      var id = DateTime.now().microsecondsSinceEpoch;
      if (id <= _lastRegionId) id = _lastRegionId + 1;
      while (usedIds.contains(id)) {
        id++;
      }
      _lastRegionId = id;
      operation.id = id;
      final context = _PackContext.fromJson(
        id: id,
        styleUrl: style,
        pixelDensity: pixelDensity,
        metadata: metadata,
      );
      final region = Helpers.createTilePyramidOfflineRegionWithStyleURL(
        style.toNSURL(),
        fromZoomLevel: minZoom,
        toZoomLevel: maxZoom,
        east: bounds.longitudeEast,
        north: bounds.latitudeNorth,
        west: bounds.longitudeWest,
        south: bounds.latitudeSouth,
      );
      late final objc.ObjCBlock<
        ffi.Void Function(MLNOfflinePack?, objc.NSError?)
      >
      block;
      block = ObjCBlock_ffiVoid_MLNOfflinePack_NSError.listener((pack, error) {
        try {
          operation.completeCreation(pack);
          if (error != null || pack == null) {
            operation.fail(
              Exception(
                error?.localizedDescription.toDartString() ??
                    'Native offline pack creation returned no pack',
              ),
            );
          } else if (_disposed || operation.cancelRequested) {
            // The cancellation future is already waiting for created. It will
            // suspend/query this pack; never activate a canceled operation.
            unawaited(
              operation.cancel().then(
                (_) => operation.close(),
                onError: operation.fail,
              ),
            );
          } else {
            pack.resume();
            operation.controller.add(pack.toDownloadProgress(_region(pack)));
          }
        } catch (error, stack) {
          operation.fail(error, stack);
        } finally {
          _pendingBlocks.remove(block);
          _detachIfIdle();
        }
      });
      _pendingBlocks.add(block);
      operation.watchCreation();
      try {
        _storage.addPackForRegion(
          region,
          withContext: context.toNSData(),
          completionHandler: block,
        );
      } catch (_) {
        _pendingBlocks.remove(block);
        rethrow;
      }
    } catch (error, stack) {
      operation.completeCreation(null);
      operation.fail(error, stack);
    }
  }

  Future<void> _seedStyle(String style, List<int> bytes) async {
    _checkUsable();
    final styleUrl = style.toNSURL();
    if (styleUrl == null) {
      throw const FormatException('Invalid offline style URL.');
    }
    final completion = Completer<void>();
    late final objc.ObjCBlock<ffi.Void Function(objc.NSURL, objc.NSError?)> block;
    block = ObjCBlock_ffiVoid_NSURL_NSError.listener((url, error) {
      try {
        if (!completion.isCompleted) {
          if (error == null) {
            completion.complete();
          } else {
            completion.completeError(StateError('Offline style preparation failed.'));
          }
        }
      } finally {
        _pendingBlocks.remove(block);
        _detachIfIdle();
      }
    });
    _pendingBlocks.add(block);
    try {
      _storage.preloadData$1(
        bytes.toNSData(),
        forURL: styleUrl,
        mustRevalidate: false,
        completionHandler: block,
      );
    } catch (_) {
      _pendingBlocks.remove(block);
      rethrow;
    }
    // Retain the callback even after timeout until native acknowledgement.
    // A late seed never creates/activates a pack; cancellation is checked above.
    await completion.future.timeout(const Duration(seconds: 10));
  }

  @override
  void dispose() {
    if (_detached) return;
    // Repeated disposal retries any previous unconfirmed suspension.
    _disposed = true;
    for (final operation in _downloads.toList()) {
      unawaited(
        operation.cancel().then(
          (_) => operation.close(),
          onError: operation.fail,
        ),
      );
    }
    _detachIfIdle();
  }

  void _detachIfIdle() {
    if (!_disposed ||
        _detached ||
        _downloads.isNotEmpty ||
        _pendingBlocks.isNotEmpty ||
        _statusWaiters.isNotEmpty)
      return;
    _detached = true;
    Helpers.removeOfflinePackProgressListenerWithCallbacks(_callbacks);
    _liveManagers.remove(this);
    // Already-queued callbacks retain this manager and immediately return when
    // detached. Shared invalid-handle tombstones remain until process restart.
  }

  Future<void> _withCompletion(
    void Function(objc.ObjCBlock<ffi.Void Function(objc.NSError?)>) start,
  ) async {
    final completer = Completer<void>();
    late final objc.ObjCBlock<ffi.Void Function(objc.NSError?)> block;
    block = ObjCBlock_ffiVoid_NSError.listener((error) {
      try {
        if (!completer.isCompleted) {
          if (error == null) {
            completer.complete();
          } else {
            completer.completeError(
              Exception(error.localizedDescription.toDartString()),
            );
          }
        }
      } finally {
        _pendingBlocks.remove(block);
        _detachIfIdle();
      }
    });
    _pendingBlocks.add(block);
    try {
      start(block);
    } catch (_) {
      _pendingBlocks.remove(block);
      rethrow;
    }
    // The caller gets bounded failure, but no timeout releases a block that
    // native code may still call. Disposal retains this manager until callback.
    return completer.future.timeout(const Duration(seconds: 30));
  }

  @override
  Future<void> clearAmbientCache() {
    _checkUsable();
    return _withCompletion(_storage.clearAmbientCacheWithCompletionHandler);
  }

  @override
  Future<void> invalidateAmbientCache() {
    _checkUsable();
    return _withCompletion(
      _storage.invalidateAmbientCacheWithCompletionHandler,
    );
  }

  @override
  Future<void> resetDatabase() async {
    _checkUsable();
    if (_downloads.isNotEmpty ||
        _statusWaiters.isNotEmpty ||
        _pendingBlocks.isNotEmpty) {
      throw StateError(
        'Cannot reset storage while offline operations are active',
      );
    }
    await _withCompletion(_storage.resetDatabaseWithCompletionHandler);
  }

  @override
  Future<void> setMaximumAmbientCacheSize({required int bytes}) {
    _checkUsable();
    return _withCompletion(
      (block) => _storage.setMaximumAmbientCacheSize(
        bytes,
        withCompletionHandler: block,
      ),
    );
  }

  @override
  void setOfflineTileCountLimit({required int amount}) {
    _checkUsable();
    _storage.setMaximumAllowedMapboxTiles(amount);
  }

  @override
  Future<List<OfflineRegion>> mergeOfflineRegions({
    required String path,
  }) async => throw UnsupportedError(
    'Importing Offline Regions is not available on iOS.',
  );

  @override
  Future<void> packDatabase() async =>
      throw UnsupportedError('The database cannot be packed on iOS.');

  @override
  void runPackDatabaseAutomatically({required bool enabled}) =>
      throw UnsupportedError('The database cannot be packed on iOS.');

  MLNOfflinePack? _notificationPack(objc.NSNotification notification) {
    if (_detached) return null;
    final pack = notification.offlinePack;
    if (pack == null || _invalidPacks.containsKey(pack.ref.pointer.address)) {
      return null;
    }
    final address = pack.ref.pointer.address;
    if (!_statusWaiters.containsKey(address) &&
        !_downloads.any(
          (operation) => operation.pack?.ref.pointer.address == address,
        ))
      return null;
    return pack;
  }

  void _onProgressChanged(objc.NSNotification notification) {
    final pack = _notificationPack(notification);
    if (pack == null) return;
    if (pack.state == MLNOfflinePackState.MLNOfflinePackStateUnknown) return;
    final OfflineRegionStatus status;
    try {
      status = _snapshot(pack);
    } catch (error) {
      _failPack(pack, error);
      return;
    }
    final waiters = _statusWaiters.remove(pack.ref.pointer.address) ?? [];
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.complete(status);
    }
    for (final operation in _downloads.toList()) {
      if (operation.id != status.region.id) continue;
      if (operation.cancelRequested) {
        // A late notification can resolve an earlier timeout conservatively.
        // Do not release the operation merely because cancellation was asked.
        if (!status.isActive) {
          operation.confirmStopped();
          operation.close();
        }
        continue;
      }
      if (operation.controller.isClosed) continue;
      operation.controller.add(status);
      if (status.downloadCompleted) {
        operation.completed = true;
        operation.close();
        _downloads.remove(operation);
      }
    }
    _detachIfIdle();
  }

  void _failPack(MLNOfflinePack pack, Object error) {
    final waiters = _statusWaiters.remove(pack.ref.pointer.address) ?? [];
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.completeError(error);
    }
    final address = pack.ref.pointer.address;
    for (final operation in _downloads.toList()) {
      if (operation.pack?.ref.pointer.address == address) operation.fail(error);
    }
  }

  void _onErrorWithNotification(objc.NSNotification notification) {
    final pack = _notificationPack(notification);
    if (pack == null) return;
    final raw = notification.userInfo?.objectForKey('Error'.toNSString());
    final message = raw != null && objc.NSError.isA(raw)
        ? objc.NSError.as(raw).localizedDescription.toDartString()
        : 'Native offline region download failed';
    _failPack(pack, Exception(message));
  }

  void _onMaximumAllowedTiles(objc.NSNotification notification) {
    final pack = _notificationPack(notification);
    if (pack == null) return;
    final raw = notification.userInfo?.objectForKey(
      'MaximumCount'.toNSString(),
    );
    final limit = raw != null && objc.NSNumber.isA(raw)
        ? objc.NSNumber.as(raw).intValue
        : null;
    _failPack(
      pack,
      StateError(
        'Native offline tile limit exceeded'
        '${limit == null ? '' : ': $limit'}',
      ),
    );
  }
}

/// Owns a native pack, completion and stream until cancellation or terminal state.
final class _IosDownload {
  _IosDownload(this.manager) {
    controller.onCancel = cancel;
  }

  final OfflineManagerIos manager;
  final controller = StreamController<DownloadProgress>();
  final created = Completer<MLNOfflinePack?>();
  MLNOfflinePack? pack;
  int? id;
  bool cancelRequested = false;
  bool completed = false;
  bool _stopped = false;
  bool _failed = false;
  Future<void>? _cancelFuture;
  Timer? _creationWatchdog;

  void completeCreation(MLNOfflinePack? nativePack) {
    _creationWatchdog?.cancel();
    _creationWatchdog = null;
    if (created.isCompleted) return;
    pack = nativePack;
    created.complete(nativePack);
  }

  void watchCreation() {
    _creationWatchdog = Timer(const Duration(seconds: 30), () {
      if (created.isCompleted || _failed) return;
      cancelRequested = true;
      _failed = true;
      // Report uncertainty promptly without discarding the callback or
      // pretending the native operation has stopped. A late pack stays gated
      // against resume and the retained cancellation task will suspend it.
      if (!controller.isClosed) {
        controller.addError(
          TimeoutException(
            'Native offline pack creation timed out; cancellation is unconfirmed',
            const Duration(seconds: 30),
          ),
        );
      }
      unawaited(
        cancel().then(
          (_) => close(),
          onError: (Object _, StackTrace __) => close(),
        ),
      );
    });
  }

  Future<void> cancel() {
    cancelRequested = true;
    if (completed || _stopped) return Future<void>.value();
    // Only the caller's wait times out. The underlying task, native completion
    // block, pack owner and observer remain alive until confirmed inactivity.
    return (_cancelFuture ??= _cancel()).timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw TimeoutException(
        'Native offline cancellation is not yet confirmed',
        const Duration(seconds: 30),
      ),
    );
  }

  Future<void> _cancel() async {
    try {
      final nativePack = await created.future;
      if (nativePack != null) await manager._suspendPack(nativePack);
      confirmStopped();
    } catch (_) {
      // Keep the owner, observer and native pack alive on an unknown/failed
      // stop. A later explicit suspend/dispose must be able to retry.
      _cancelFuture = null;
      rethrow;
    }
  }

  void confirmStopped() {
    _stopped = true;
    manager._downloads.remove(this);
    manager._detachIfIdle();
  }

  void close() {
    if (!controller.isClosed) {
      // Any cancellation failure is reported by cancel()/the terminal stream
      // error. A duplicate cleanup-close failure must not be unhandled.
      unawaited(controller.close().catchError((Object _, StackTrace __) {}));
    }
  }

  void fail(Object error, [StackTrace? stack]) {
    if (_failed) return;
    _failed = true;
    // Stop native work before delivering a terminal error/closing the stream.
    unawaited(
      cancel().then(
        (_) {
          if (!controller.isClosed) controller.addError(error, stack);
          close();
        },
        onError: (Object stopError, StackTrace stopStack) {
          if (!controller.isClosed) {
            controller.addError(stopError, stopStack);
          }
          close();
        },
      ),
    );
  }
}

extension type const _PackContext(Map<String, Object?> data) {
  _PackContext.fromJson({
    required int id,
    required String styleUrl,
    required double pixelDensity,
    required Map<String, Object?> metadata,
  }) : this({
         'id': id,
         'styleUrl': styleUrl,
         'pixelRatio': pixelDensity,
         'metadata': metadata,
       });

  _PackContext.fromNSData(objc.NSData data)
    : this(decodeOfflinePackContext(data.toList()));

  int get id => data['id'] is int ? data['id']! as int : -1;

  String get styleUrl =>
      data['styleUrl'] is String ? data['styleUrl']! as String : '';

  double get pixelDensity =>
      data['pixelRatio'] is num ? (data['pixelRatio']! as num).toDouble() : 1;

  // TODO remove old metadata structure in favor of the new one, but keep it for backwards compatibility for now
  Map<String, Object?> get metadata => data['metadata'] is Map<String, dynamic>
      ? (data['metadata']! as Map<String, dynamic>).cast<String, Object?>()
      : data;

  objc.NSData toNSData() => utf8.encode(jsonEncode(data)).toNSData();
}
