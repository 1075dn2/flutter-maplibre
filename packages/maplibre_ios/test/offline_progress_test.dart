import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_ios/src/offline_progress.dart';

void main() {
  test(
    'lower-bound count is never enough to declare native offline readiness',
    () {
      expect(
        hasCompleteOfflineResources(
          nativeComplete: false,
          completedResources: 12,
          requiredResources: 12,
          maximumRequiredResources: 99,
        ),
        isFalse,
      );
    },
  );

  test('native complete requires precise resource totals', () {
    expect(
      hasCompleteOfflineResources(
        nativeComplete: true,
        completedResources: 12,
        requiredResources: 12,
        maximumRequiredResources: 99,
      ),
      isFalse,
    );
  });

  test('precise totals do not override active native state', () {
    expect(
      hasCompleteOfflineResources(
        nativeComplete: false,
        completedResources: 12,
        requiredResources: 12,
        maximumRequiredResources: 12,
      ),
      isFalse,
    );
  });

  test('zero lazy defaults and missing resources are not complete', () {
    for (final completed in [0, 11]) {
      expect(
        hasCompleteOfflineResources(
          nativeComplete: true,
          completedResources: completed,
          requiredResources: completed == 0 ? 0 : 12,
          maximumRequiredResources: completed == 0 ? 0 : 12,
        ),
        isFalse,
      );
    }
  });

  test('native complete and precise full resource coverage are ready', () {
    for (final completed in [12, 13]) {
      expect(
        hasCompleteOfflineResources(
          nativeComplete: true,
          completedResources: completed,
          requiredResources: 12,
          maximumRequiredResources: 12,
        ),
        isTrue,
      );
    }
  });
}
