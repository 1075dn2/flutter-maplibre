import 'package:flutter/widgets.dart';

/// Balances native MapView lifecycle calls, including permission-dialog races.
///
/// Flutter can resume before the platform view exists. Recording that event
/// must not mark a nonexistent native view as started. An inactive app remains
/// visible (for example behind a permission dialog), so it pauses but does not
/// stop the native view until hidden or paused.
final class MapViewLifecycle {
  VoidCallback? _start;
  VoidCallback? _resume;
  VoidCallback? _pause;
  VoidCallback? _stop;
  VoidCallback? _destroy;
  bool _started = false;
  bool _resumed = false;
  bool _disposed = false;

  /// Whether native lifecycle work must no longer be accepted.
  bool get isDisposed => _disposed;

  /// Attaches one native view and synchronizes it to the actual app state.
  void attach({
    required VoidCallback start,
    required VoidCallback resume,
    required VoidCallback pause,
    required VoidCallback stop,
    required VoidCallback destroy,
    required AppLifecycleState? state,
  }) {
    if (_disposed) return;
    assert(_start == null, 'A lifecycle coordinator owns one native view.');
    _start = start;
    _resume = resume;
    _pause = pause;
    _stop = stop;
    _destroy = destroy;
    update(state ?? AppLifecycleState.resumed);
  }

  /// Applies a Flutter lifecycle transition if a native view exists.
  void update(AppLifecycleState state) {
    if (_disposed || _start == null) return;
    final visible =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    if (visible && !_started) {
      _start!();
      _started = true;
    }
    if (state == AppLifecycleState.resumed) {
      if (!_resumed) {
        _resume!();
        _resumed = true;
      }
    } else {
      if (_resumed) {
        _pause!();
        _resumed = false;
      }
      if (!visible && _started) {
        _stop!();
        _started = false;
      }
    }
  }

  /// Pauses/stops once before destroying, and ignores all late transitions.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_resumed) _pause!();
    if (_started) _stop!();
    _destroy?.call();
    _resumed = false;
    _started = false;
    _start = _resume = _pause = _stop = _destroy = null;
  }
}
