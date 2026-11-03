// Host Dart probe, not a JNI/device rendering test. Run from any directory:
// dart flutter-maplibre/tool/style_callback_lifetime_probe.dart
// Models the exact retained-vs-ephemeral method tear-off ownership in map_state.
import 'dart:io';
import 'dart:typed_data';

class _MapState {
  int callbacks = 0;
  late final void Function() retainedCallback = onStyleLoaded;
  void onStyleLoaded() => callbacks++;
}

@pragma('vm:never-inline')
WeakReference<void Function()> _oldCallback(_MapState owner) =>
    WeakReference(owner.onStyleLoaded);

@pragma('vm:never-inline')
(WeakReference<_MapState>, WeakReference<void Function()>) _releasedOwner() {
  final owner = _MapState();
  return (WeakReference(owner), WeakReference(owner.retainedCallback));
}

Future<bool> _collectUntil(bool Function() done) async {
  for (var i = 0; i < 500; i++) {
    // Force allocation pressure without VM-service access or platform plugins.
    final allocations = List.generate(1000, (_) => Uint8List(1024));
    if (allocations.first.length != 1024) throw StateError('allocation failed');
    await Future<void>.delayed(Duration.zero);
    if (done()) return true;
  }
  // GC is intentionally not guaranteed by Dart, so report inconclusive rather
  // than converting absence of collection into a false correctness claim.
  return false;
}

Future<void> main() async {
  final source = File.fromUri(
    Platform.script.resolve(
      '../packages/maplibre_android/lib/src/map_state.dart',
    ),
  ).readAsStringSync();
  if (!source.contains('_styleLoadedCallback = onStyleLoaded;') ||
      !source.contains('WeakReference(_styleLoadedCallback)') ||
      source.contains('WeakReference(onStyleLoaded)')) {
    throw StateError('Android source does not use the retained callback fix');
  }

  final oldOwner = _MapState();
  final old = _oldCallback(oldOwner);
  final fixedOwner = _MapState();
  final fixed = WeakReference(fixedOwner.retainedCallback);
  if (!await _collectUntil(() => old.target == null)) {
    stderr.writeln('INCONCLUSIVE: old tear-off was not collected this run.');
    exitCode = 2;
    return;
  }
  // Both map-state owners remain strongly reachable at this point.
  oldOwner.onStyleLoaded();
  fixed.target!();
  if (oldOwner.callbacks != 1 || fixedOwner.callbacks != 1) {
    throw StateError('Retained callback failed while map state is alive');
  }
  print(
    'PASS: old JNI-shaped weak tear-off was lost while owner stayed alive.',
  );
  print('PASS: State-retained callback survived the same collection pressure.');

  final disposed = _releasedOwner();
  if (!await _collectUntil(
    () => disposed.$1.target == null && disposed.$2.target == null,
  )) {
    stderr.writeln('INCONCLUSIVE: abandoned owner was not collected this run.');
    exitCode = 2;
    return;
  }
  print('PASS: weak JNI-shaped reference did not retain the abandoned state.');
  print('Native callback dispatch and visible controls still require Android.');
}
