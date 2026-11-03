# maplibre_ios

iOS implementation for [maplibre](https://pub.dev/packages/maplibre).

## Offline-region lifecycle

`getOfflineRegionStatus` requests a fresh native progress notification; unknown,
timed-out or invalidated packs throw rather than reporting readiness. Completion
requires the native complete state, precise resource totals and nonzero completed
resources. The historical `loadedTiles`/`totalTiles` names count all native
resources (including style, glyph and sprite resources), not only map tiles.

Canceling a download subscription awaits pack creation when necessary, prevents
activation after an early cancel, suspends the native pack and checks its native
inactive state. `suspendOfflineRegion` does the same for an existing ID. Neither
operation deletes a completed or partial region. The SDK may still finish
already-queued network work while suspension takes effect; this is not an
instantaneous network-drain guarantee. A failed or timed-out suspension remains
an error and retains its operation/observer until inactivity is confirmed. An
explicit suspension (or repeated disposal) can retry it; a late inactive native
notification can also complete safe cleanup. Creation and cancellation waits
report an explicit timeout after 30 seconds without releasing a native callback
that may still arrive; a late-created pack is never activated after cancellation.

`deleteOfflineRegion` suspends only the specified region, then requests removal.
An unknown ID fails. Removal invalidates the Objective-C pack immediately, even
if the callback later reports an error. Invalid-handle tombstones are retained
for the process lifetime so late callbacks and recreated managers cannot message
those handles. A failed removal requires restarting the app before retrying;
this implementation deliberately does not suspend unrelated packs or reload the
global storage. The caller must validate application ownership metadata before
suspending or deleting a persisted region.

Offline-region readiness is an SDK resource snapshot, not cryptographic
coursepack verification or a cache-only/network-isolation mode. Provider access
and production download rights remain the application's responsibility.

The pure resource-completion predicate has Linux-runnable unit tests. Native
creation/cancellation/status/deletion races still require iOS device validation;
Dart analysis alone is not an Xcode build or device verification.
