import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/src/map_view_lifecycle.dart';

void main() {
  late MapViewLifecycle lifecycle;
  late List<String> calls;
  void attach(AppLifecycleState? state) => lifecycle.attach(
    start: () => calls.add('start'),
    resume: () => calls.add('resume'),
    pause: () => calls.add('pause'),
    stop: () => calls.add('stop'),
    destroy: () => calls.add('destroy'),
    state: state,
  );
  setUp(() {
    lifecycle = MapViewLifecycle();
    calls = [];
  });

  test('permission resume before native creation does not consume start', () {
    lifecycle.update(AppLifecycleState.inactive);
    lifecycle.update(AppLifecycleState.resumed);
    expect(calls, isEmpty);
    attach(AppLifecycleState.resumed);
    expect(calls, ['start', 'resume']);
  });

  test('visible permission dialog pauses without stopping native view', () {
    attach(AppLifecycleState.resumed);
    lifecycle.update(AppLifecycleState.inactive);
    lifecycle.update(AppLifecycleState.inactive);
    expect(calls, ['start', 'resume', 'pause']);
    lifecycle.update(AppLifecycleState.resumed);
    lifecycle.update(AppLifecycleState.resumed);
    expect(calls, ['start', 'resume', 'pause', 'resume']);
  });

  test('creation behind permission dialog starts but waits to resume', () {
    attach(AppLifecycleState.inactive);
    expect(calls, ['start']);
    lifecycle.update(AppLifecycleState.resumed);
    expect(calls, ['start', 'resume']);
  });

  test('hidden paused detached sequence stops once and resumes in order', () {
    attach(AppLifecycleState.resumed);
    lifecycle.update(AppLifecycleState.inactive);
    lifecycle.update(AppLifecycleState.hidden);
    lifecycle.update(AppLifecycleState.paused);
    lifecycle.update(AppLifecycleState.detached);
    expect(calls, ['start', 'resume', 'pause', 'stop']);
    lifecycle.update(AppLifecycleState.hidden);
    lifecycle.update(AppLifecycleState.inactive);
    lifecycle.update(AppLifecycleState.resumed);
    expect(calls, ['start', 'resume', 'pause', 'stop', 'start', 'resume']);
  });

  test('background creation does not start until visible', () {
    attach(AppLifecycleState.paused);
    expect(calls, isEmpty);
    lifecycle.update(AppLifecycleState.resumed);
    expect(calls, ['start', 'resume']);
  });

  test('unknown initial lifecycle supports integration-test startup', () {
    attach(null);
    expect(calls, ['start', 'resume']);
  });

  test(
    'disposal balances started resumed view once and ignores late events',
    () {
      attach(AppLifecycleState.resumed);
      lifecycle.dispose();
      lifecycle.dispose();
      lifecycle.update(AppLifecycleState.resumed);
      expect(calls, ['start', 'resume', 'pause', 'stop', 'destroy']);
      expect(lifecycle.isDisposed, isTrue);
    },
  );

  test('dispose while inactive stops without a duplicate pause', () {
    attach(AppLifecycleState.inactive);
    lifecycle.dispose();
    expect(calls, ['start', 'stop', 'destroy']);
  });

  test('dispose before native creation ignores late attachment', () {
    lifecycle.dispose();
    attach(AppLifecycleState.resumed);
    lifecycle.update(AppLifecycleState.resumed);
    expect(calls, isEmpty);
  });
}
