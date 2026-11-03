# Native offline region lifecycle

Added APIs (exported from `maplibre` and `maplibre_platform_interface`):

- `getOfflineRegionStatus(regionId:)` → `OfflineRegionStatus` extends
  `DownloadProgress`, adding `isActive`.
- `suspendOfflineRegion(regionId:)` confirms the native SDK reports inactive.
- `deleteOfflineRegion(regionId:)` is a separate, explicit removal operation.

Applications must validate their own metadata ownership before suspend/delete.
Unknown regions, timeout and native failures throw; none means Ready or canceled.
A native snapshot is **not** cryptographic coursepack verification or a promise
of network-free rendering. Resource counts retain the historical `loadedTiles`
and `totalTiles` names. Mapbox's native tile-count cap does not bound arbitrary
IHM/GovMap providers. Application geometry/zoom/budget limits remain necessary.

## Cancellation and retained references

The download starts only when its stream is listened to. Await subscription
cancellation before disposing a manager when confirmation is needed. Cancellation
is suspend + inactive status confirmation; it never deletes any region, including
a completed one. Already-queued network requests may finish after suspension.

Cancellation before creation waits for the created region and prevents activation.
The caller may not receive that region's ID after unsubscribe. Put a unique
operation ID in metadata before starting; after confirmed cancellation, enumerate
regions and explicitly delete only the matching owned partial if desired.

Android creation/cancellation and region operations report timeout after 30s.
Timeout does not release still-callable JNI references or claim inactivity.
Underlying creation remains cancellation-gated; a late callback suspends and
releases safely. Indefinitely missing native callbacks intentionally retain their
small operation/manager until process end rather than create a dangling callback.
Failed suspend/detach retains handles and permits retry. Android uses the exact
Java handle that activated a region, since a fresh handle starts inactive and its
`setDownloadState(INACTIVE)` may otherwise be a no-op. Each region's explicit
queries/mutations are serialized within its manager.

One-shot callbacks use strongly retained completers and async arenas. Incoming
late callback arguments are released without touching disposed handles. Manager
`dispose()` is idempotent and keeps active operations alive until safe cleanup;
its legacy void signature is not an acknowledgement of native cancellation.

On iOS fresh status requires `requestProgress()` and a notification; unknown
state cannot be Ready. Ready requires native Complete, precise expected resource
counts, and full nonempty resource coverage. Pack removal invalidates objects
immediately even if it fails, so tombstones survive manager recreation until
process restart; failed removal never triggers a global reload/suspend of foreign
packs. See the iOS README for those source-level guarantees and limitations.

Foreign non-JSON metadata is not interpreted as application ownership. UTF-8
metadata, including signed Java byte values for Hebrew, is preserved.

## Validation boundary

Pure lifecycle tests exercise the actual Android production state machine with a
fake native handle, including early cancellation, missing/late callbacks, failed
suspension retry, completion, cleanup and metadata preservation. Separate pure
iOS predicates cover false-completion lower bounds and foreign context decoding.
They do not execute JNI/ObjC, provider tile requests or native map rendering.

Android integration compile uses a separate temporary app checkout at `bc10fb5`,
all five MapLibre path overrides pointing at this isolated fork, and a reachable
compile-only button callback referencing download/status/suspend/delete. The
probe is never installed, launched, shipped or uploaded. No iOS build/device
claim is made without Xcode.

GovMap's existing Android `HttpRequestUtil` client is shared by native HTTP
requests (including the offline path according to SDK source/bytecode); actual
provider header delivery remains device-unverified. No request headers, network
policy, keys, provider sources, permission, or global connectivity toggle were
changed by this patch. Provider production rights/limits remain release checks.
