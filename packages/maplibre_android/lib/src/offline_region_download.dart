import 'dart:async';

import 'package:maplibre_platform_interface/maplibre_platform_interface.dart';

/// Internal native handle contract, separated to test cancellation without JNI.
abstract interface class OfflineDownloadHandle {
  /// Persisted region including caller metadata.
  OfflineRegion get region;

  /// Attach progress callbacks, retaining them until [suspendAndDetach].
  void observe(
    void Function(DownloadProgress) progress,
    void Function(Object) error,
  );

  /// Activate the download. Called only after the cancellation gate.
  void activate();

  /// Confirm inactive, then detach observers. Failures must preserve the handle.
  Future<void> suspendAndDetach();

  /// Release owned native handles, after confirmed detachment only.
  void release();
}

/// Internal, single-subscription native download lifecycle.
///
/// A failed suspension is retryable and does not release native callbacks. Stream
/// cancellation never deletes a region. Creation starts only on listen.
class OfflineRegionDownload {
  /// Creates an operation whose native factory retains pending callbacks.
  OfflineRegionDownload({
    required this.create,
    required this.onStart,
    required this.onFinish,
    this.operationTimeout = const Duration(seconds: 30),
  }) {
    _controller = StreamController<DownloadProgress>(
      onListen: _start,
      onCancel: () => _finished ? null : cancel(),
    );
  }

  /// Native creation factory; invoked at most once.
  final Future<OfflineDownloadHandle> Function() create;

  /// Registers this operation with its owner and checks disposal.
  final void Function() onStart;

  /// Removes this operation from its owner after native cleanup.
  final void Function() onFinish;

  /// Deadline for reporting an unconfirmed operation, without releasing handles.
  final Duration operationTimeout;

  late final StreamController<DownloadProgress> _controller;
  final _created = Completer<Object?>();
  OfflineDownloadHandle? _handle;
  Future<void>? _stopFuture;
  Object? _creationError;
  Timer? _creationTimer;
  var _started = false;
  var _stopping = false;
  var _canceled = false;
  var _finished = false;

  /// Progress stream. Canceling its subscription awaits native suspension.
  Stream<DownloadProgress> get stream => _controller.stream;

  /// Available as soon as native creation finishes.
  int? get regionId => _handle?.region.id;

  /// Preparation must not enqueue more work after cancellation.
  bool get isCancellationRequested => _stopping || _canceled;

  void _start() {
    _started = true;
    _creationTimer = Timer(operationTimeout, () {
      reportError(TimeoutException('Native offline region creation timed out'));
      // Keep the pending factory alive. If creation eventually completes, the
      // cancellation gate prevents activation and confirms suspension.
      unawaited(cancel().catchError((Object _) {}));
    });
    unawaited(_create());
  }

  Future<void> _create() async {
    try {
      onStart();
      _handle = await create();
      _creationTimer?.cancel();
    } catch (error) {
      _creationTimer?.cancel();
      _creationError = error;
      _created.complete(error);
      _cleanup();
      reportError(error);
      unawaited(_controller.close());
      return;
    }
    final handle = _handle!;
    try {
      handle.observe(_progress, (error) => unawaited(_fail(error)));
      _created.complete(null);
      if (!_stopping) {
        _controller.add(
          DownloadProgress(
            loadedBytes: 0,
            loadedTiles: 0,
            totalTilesEstimated: true,
            totalTiles: 0,
            region: handle.region,
            downloadCompleted: false,
          ),
        );
        handle.activate();
      }
    } catch (error) {
      if (!_created.isCompleted) _created.complete(null);
      unawaited(_fail(error));
    }
  }

  void _progress(DownloadProgress progress) {
    if (_stopping || _finished) return;
    if (progress.downloadCompleted) {
      unawaited(_complete(progress));
    } else if (!_controller.isClosed) {
      _controller.add(progress);
    }
  }

  Future<void> _complete(DownloadProgress progress) async {
    try {
      await _stop();
      if (!_canceled && !_controller.isClosed) _controller.add(progress);
      unawaited(_controller.close());
    } catch (error) {
      reportError(error);
    }
  }

  Future<void> _fail(Object error) async {
    if (_stopping || _finished) return;
    try {
      await _stop();
      reportError(error);
      unawaited(_controller.close());
    } catch (stopError) {
      reportError(error);
      reportError(stopError);
    }
  }

  /// Reports a failure while an active listener still exists.
  void reportError(Object error) {
    if (!_controller.isClosed && !_canceled) _controller.addError(error);
  }

  /// Suspends without deleting; safe before creation or after completion.
  Future<void> cancel() async {
    _canceled = true;
    // Do not timeout the underlying stop itself: it still owns JNI references
    // and must suspend a late-created region, even after the caller sees error.
    await _stop().timeout(operationTimeout);
    unawaited(_controller.close());
  }

  Future<void> _stop() {
    _stopping = true;
    return _stopFuture ??= _stopOnce().catchError((Object error) {
      _stopFuture = null;
      throw error;
    });
  }

  Future<void> _stopOnce() async {
    if (_creationError != null) throw _creationError!;
    if (!_started || _finished) return;
    final error = await _created.future;
    if (error != null) throw error;
    final handle = _handle;
    if (handle == null)
      throw StateError('Native offline region was not created');
    await handle.suspendAndDetach();
    _cleanup();
  }

  void _cleanup() {
    if (_finished) return;
    _finished = true;
    _handle?.release();
    onFinish();
  }
}
