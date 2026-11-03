# Android local-style offline bootstrap

Android Native 12.3.1's renderer supports local style files, but its offline
downloader uses the database followed by the network file source. A file URL
missing from the database reaches `HttpRequestImpl`, where `HttpUrl.parse`
returns null; that branch logs and returns without a response callback. Thus a
locally rendered map is not evidence its offline region can bootstrap.

The Android adapter now reads a `file:` style before region creation and inserts
its bytes with the existing `OfflineManager.putResourceWithUrl` API. It keeps
the exact original URL, file, region metadata and renderer reopening behavior.
Remote styles and iOS are unchanged. No server, fake hostname, provider request,
HTTP header, connectivity override or network-security change is introduced.

## Source proof (pinned Android 12.3.1)

All links below refer to the existing SDK tag, not current main:

- [JNI manager](https://github.com/maplibre/maplibre-native/blob/android-v12.3.1/platform/android/MapLibreAndroid/src/cpp/offline/offline_manager.cpp):
  `putResourceWithUrl` builds `Resource::Kind::Unknown` and calls the manager's
  `DatabaseFileSource::put`.
- [Database](https://github.com/maplibre/maplibre-native/blob/android-v12.3.1/platform/default/src/mbgl/storage/offline_database.cpp):
  `putInternal` and `getInternal` distinguish tiles from all other kinds. Non-tile
  `getResource` selects by URL only. `getRegionResource` calls `getInternal`,
  without requiring prior region association. `markUsed` inserts that resource
  into `region_resources` by URL, protecting it as regional data thereafter.
- [Offline download](https://github.com/maplibre/maplibre-native/blob/android-v12.3.1/platform/default/src/mbgl/storage/offline_download.cpp):
  `ensureResource` reads `getRegionResource` before its network fallback. A hit
  parses the style, increments real resource counts/bytes, and queues the used
  resource for association with the region. This direct database read does not
  use `DatabaseFileSource::canRequest`, which excludes file URLs for renderer
  routing. The renderer still uses the retained local file when reopening.
- [Database actor](https://github.com/maplibre/maplibre-native/blob/android-v12.3.1/platform/default/src/mbgl/storage/database_file_source.cpp):
  `put` and `createOfflineRegion` invoke the same `impl->actor()`. `createRegion`
  calls its callback after its database operation.
- [ActorRef](https://github.com/maplibre/maplibre-native/blob/android-v12.3.1/include/mbgl/actor/actor_ref.hpp)
  enqueues each invocation, and [Mailbox](https://github.com/maplibre/maplibre-native/blob/android-v12.3.1/src/mbgl/actor/mailbox.cpp)
  processes its queue in FIFO order under a receiving lock.

The adapter synchronously enqueues seed before creation; the existing awaited
`onCreate` callback is therefore a write-completion ordering barrier before
`STATE_ACTIVE`, not a timer-based guess. Existing cancellation gates still
prevent activation after canceled/late creation. `setDownloadState(ACTIVE)`
already activates both FileSource and ConnectivityReceiver in SDK 12.3.1;
additional activation would unbalance SDK lifecycle counters.

## Honest verification boundary

The seed API is void and the database write catches errors internally. Creation
acknowledges ordering, **not successful seed persistence**. Failed writes must
remain failures/stalls, never Ready: actual native resource progress and the
application's startup/stall watchdog are still required. No callback or timer
can turn the void API into a persistence acknowledgment.

The helper tests cover exact bytes, URI-escaped local paths, seed-before-create
ordering, waiting for creation acknowledgment, remote bypass, missing/empty
files and propagated seed/creation failures. Existing lifecycle tests cover
cancel-before-create, late callbacks and handle retention. These tests do not
execute Android JNI, SQLite or provider downloads. Device validation must show
real status bytes beyond the synthetic initial zero event, completion, reopening
without network, and cancellation/retry. iOS behavior is unchanged and untested
on device here.
