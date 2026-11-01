import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre/maplibre.dart';
// Tests the actual production lifecycle independently of JNI/device networking.
// ignore: implementation_imports
import 'package:maplibre_android/src/offline_region_download.dart';
// ignore: implementation_imports
import 'package:maplibre_android/src/offline_metadata.dart';

const _region = OfflineRegion(
  id: 42,
  bounds: LngLatBounds(
    longitudeWest: 1,
    longitudeEast: 2,
    latitudeSouth: 1,
    latitudeNorth: 2,
  ),
  minZoom: 1,
  maxZoom: 2,
  pixelRatio: 1,
  styleUrl: 'https://example.invalid/test-style',
  metadata: {'owner': 'test', 'operation': 'unique-download'},
);

DownloadProgress _progress({bool complete = false}) => DownloadProgress(
  loadedBytes: 100,
  loadedTiles: 3,
  totalTilesEstimated: !complete,
  totalTiles: 3,
  region: _region,
  downloadCompleted: complete,
);

class _Handle implements OfflineDownloadHandle {
  int activations = 0;
  int suspensions = 0;
  int releases = 0;
  Object? suspendFailure;
  Completer<void>? suspendGate;
  late void Function(DownloadProgress) progress;
  late void Function(Object) error;

  @override
  OfflineRegion get region => _region;
  @override
  void observe(
    void Function(DownloadProgress) progress,
    void Function(Object) error,
  ) {
    this.progress = progress;
    this.error = error;
  }

  @override
  void activate() => activations++;
  @override
  Future<void> suspendAndDetach() async {
    suspensions++;
    if (suspendFailure case final failure?) throw failure;
    if (suspendGate case final gate?) await gate.future;
  }

  @override
  void release() => releases++;
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'signed Java UTF-8 metadata preserves Hebrew and rejects foreign ownership',
    () {
      final metadata = {'owner': 'test', 'name': 'מפת ניווט'};
      final bytes = utf8.encode(jsonEncode(metadata));
      expect(
        decodeOfflineMetadata(
          bytes.map((byte) => byte > 127 ? byte - 256 : byte),
        ),
        metadata,
      );
      for (final foreign in ['not json', '[1,2]', 'null']) {
        expect(decodeOfflineMetadata(utf8.encode(foreign)), isEmpty);
      }
      expect(decodeOfflineMetadata([0xff, 0xfe]), isEmpty);
    },
  );
  test(
    'native creation is lazy and first event includes ownership metadata',
    () async {
      final handle = _Handle();
      var creates = 0;
      var finishes = 0;
      final operation = OfflineRegionDownload(
        create: () async {
          creates++;
          return handle;
        },
        onStart: () {},
        onFinish: () => finishes++,
      );
      expect(creates, 0);
      final events = <DownloadProgress>[];
      final subscription = operation.stream.listen(events.add);
      await _flush();
      expect(creates, 1);
      expect(handle.activations, 1);
      expect(events.single.region.metadata, _region.metadata);
      await subscription.cancel();
      expect(handle.suspensions, 1);
      expect(handle.releases, 1);
      expect(finishes, 1);
    },
  );

  test(
    'cancel before create waits, never activates, confirms stop, preserves region',
    () async {
      final creation = Completer<OfflineDownloadHandle>();
      final handle = _Handle()..suspendGate = Completer<void>();
      var finished = false;
      final operation = OfflineRegionDownload(
        create: () => creation.future,
        onStart: () {},
        onFinish: () => finished = true,
      );
      final subscription = operation.stream.listen((_) {});
      var canceled = false;
      final cancellation = subscription.cancel().then((_) => canceled = true);
      await _flush();
      expect(canceled, isFalse);
      creation.complete(handle);
      await _flush();
      expect(handle.activations, 0);
      expect(handle.suspensions, 1);
      expect(handle.releases, 0);
      expect(canceled, isFalse);
      handle.suspendGate!.complete();
      await cancellation;
      expect(handle.releases, 1);
      expect(finished, isTrue);
      expect(operation.regionId, _region.id);
    },
  );

  test(
    'failed suspension is not cancellation success and preserves callback handles for retry',
    () async {
      final handle = _Handle()..suspendFailure = StateError('still active');
      var finishes = 0;
      final operation = OfflineRegionDownload(
        create: () async => handle,
        onStart: () {},
        onFinish: () => finishes++,
      );
      final subscription = operation.stream.listen((_) {});
      await _flush();
      await expectLater(subscription.cancel(), throwsStateError);
      expect(handle.releases, 0);
      expect(finishes, 0);
      handle.suspendFailure = null;
      await operation.cancel();
      expect(handle.suspensions, 2);
      expect(handle.releases, 1);
      expect(finishes, 1);
    },
  );

  test(
    'completion waits for stop then emits terminal progress; late callbacks and cancel are safe',
    () async {
      final handle = _Handle()..suspendGate = Completer<void>();
      var finishes = 0;
      final operation = OfflineRegionDownload(
        create: () async => handle,
        onStart: () {},
        onFinish: () => finishes++,
      );
      final events = <DownloadProgress>[];
      final errors = <Object>[];
      final done = Completer<void>();
      final subscription = operation.stream.listen(
        events.add,
        onError: errors.add,
        onDone: done.complete,
      );
      await _flush();
      handle.progress(_progress(complete: true));
      await _flush();
      expect(events.where((event) => event.downloadCompleted), isEmpty);
      expect(handle.releases, 0);
      handle.suspendGate!.complete();
      await done.future;
      expect(events.last.downloadCompleted, isTrue);
      handle.progress(_progress());
      handle.error(StateError('late callback'));
      await subscription.cancel();
      await operation.cancel();
      expect(handle.releases, 1);
      expect(handle.suspensions, 1);
      expect(finishes, 1);
      expect(errors, isEmpty);
    },
  );

  test(
    'creation failure is explicit, closes stream and releases owner',
    () async {
      var finishes = 0;
      final operation = OfflineRegionDownload(
        create: () async => throw StateError('create failed'),
        onStart: () {},
        onFinish: () => finishes++,
      );
      final errors = <Object>[];
      final done = Completer<void>();
      operation.stream.listen(
        (_) {},
        onError: errors.add,
        onDone: done.complete,
      );
      await done.future;
      expect(errors.single, isA<StateError>());
      expect(finishes, 1);
      await expectLater(operation.cancel(), throwsStateError);
    },
  );

  test('owner disposed before listen never creates native resources', () async {
    var creates = 0;
    var finishes = 0;
    final operation = OfflineRegionDownload(
      create: () async {
        creates++;
        return _Handle();
      },
      onStart: () => throw StateError('disposed'),
      onFinish: () => finishes++,
    );
    final errors = <Object>[];
    final done = Completer<void>();
    operation.stream.listen((_) {}, onError: errors.add, onDone: done.complete);
    await done.future;
    expect(creates, 0);
    expect(errors.single, isA<StateError>());
    expect(finishes, 1);
  });

  test(
    'native error suspends before closing and releases exactly once',
    () async {
      final handle = _Handle();
      final operation = OfflineRegionDownload(
        create: () async => handle,
        onStart: () {},
        onFinish: () {},
      );
      final errors = <Object>[];
      final done = Completer<void>();
      operation.stream.listen(
        (_) {},
        onError: errors.add,
        onDone: done.complete,
      );
      await _flush();
      handle.error(StateError('provider denied'));
      await done.future;
      expect(errors.single, isA<StateError>());
      expect(handle.suspensions, 1);
      expect(handle.releases, 1);
      expect(handle.activations, 1);
    },
  );

  test(
    'cancellation timeout retains pending native handles and stops a late creation',
    () async {
      final creation = Completer<OfflineDownloadHandle>();
      final handle = _Handle();
      var finishes = 0;
      final operation = OfflineRegionDownload(
        create: () => creation.future,
        onStart: () {},
        onFinish: () => finishes++,
        operationTimeout: const Duration(milliseconds: 10),
      );
      final subscription = operation.stream.listen((_) {});
      await expectLater(
        subscription.cancel(),
        throwsA(isA<TimeoutException>()),
      );
      expect(finishes, 0);
      expect(handle.releases, 0);
      creation.complete(handle);
      await _flush();
      expect(handle.activations, 0);
      expect(handle.suspensions, 1);
      expect(handle.releases, 1);
      expect(finishes, 1);
    },
  );

  test(
    'stalled creation emits explicit timeout while retaining safe late cleanup',
    () async {
      final creation = Completer<OfflineDownloadHandle>();
      final handle = _Handle();
      final errors = <Object>[];
      final operation = OfflineRegionDownload(
        create: () => creation.future,
        onStart: () {},
        onFinish: () {},
        operationTimeout: const Duration(milliseconds: 10),
      );
      final subscription = operation.stream.listen((_) {}, onError: errors.add);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(errors.single, isA<TimeoutException>());
      creation.complete(handle);
      await _flush();
      await subscription.cancel();
      expect(handle.activations, 0);
      expect(handle.releases, 1);
    },
  );

  test(
    'fresh native status includes activity in equality and preserves resource semantics',
    () {
      OfflineRegionStatus status(bool active) => OfflineRegionStatus(
        loadedBytes: 100,
        loadedTiles: 3,
        totalTilesEstimated: false,
        totalTiles: 3,
        region: _region,
        downloadCompleted: true,
        isActive: active,
      );
      expect(status(false), status(false));
      expect(status(false), isNot(status(true)));
      expect(status(false).hashCode, isNot(status(true).hashCode));
      expect(status(false).progress, 1);
      expect(status(false).toString(), contains('isActive: false'));
    },
  );
}
