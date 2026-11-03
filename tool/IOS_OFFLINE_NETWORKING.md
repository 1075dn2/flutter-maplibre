# iOS offline persistence and request policy

Prepared 2026-11-01. **Source implementation, not an iOS build/device pass.**
No provider headers are configured, no provider requests are enabled by this
patch, and the app's existing `govMapSupported = Platform.isAndroid` gate stays.

## Verified native architecture

SPM currently requests MapLibre6.21.x; the CocoaPods declaration `~>6.21` is
broader. Resolve and record the actual Mac dependency lock before validation.
These findings were checked against official `ios-v6.21.0` source:

- `MLNOfflineStorage.mm:265–295`: database under Application Support, not
  purgeable Caches. Excluded from iCloud backup. Offline packs do not count
  toward ambient-cache eviction limits. App deletion still removes them.
- `offline_download.cpp:519` → `online_file_source.cpp:151` → Darwin
  `http_file_source.mm:294`: offline and online resource requests use the same
  request hook immediately before URLSession data task creation.
- `MLNNetworkConfiguration.h`: weak delegate and optional `willSendRequest:`;
  experimental custom-session callback, no background URLSession and no
  URLSessionDataDelegate support.
- `MLNOfflineStorage.mm:624–650`: preload accepts exact bytes and original URL.
  Completion dispatches after DB forward processing, but always passes nil
  error. It does **not** prove a successful write. Native download completion
  remains the sole Ready authority.

Primary source links:
https://github.com/maplibre/maplibre-native/blob/ios-v6.21.0/platform/darwin/src/MLNOfflineStorage.mm
https://github.com/maplibre/maplibre-native/blob/ios-v6.21.0/platform/darwin/src/MLNNetworkConfiguration.h
https://github.com/maplibre/maplibre-native/blob/ios-v6.21.0/platform/darwin/core/http_file_source.mm
https://github.com/maplibre/maplibre-native/blob/ios-v6.21.0/platform/default/src/mbgl/storage/offline_download.cpp

## Implementation

`seedLocalOfflineStyle` reads exact local bytes without modifying file URLs or
JSON; remote styles bypass it. The iOS manager awaits the existing generated
`preloadData$1` callback before creating the pack. Cancellation/disposal is
rechecked before pack creation. A timeout fails without creating a pack; late
callbacks only release retained blocks and never independently start work.
This does not require regenerating FFI bindings.

`ScopedRequestPolicy` is immutable and permits only one exact HTTPS hostname,
443/default port, no credentials/fragment, and a slash-bounded unescaped path
prefix. Only explicitly configured Accept/User-Agent/Referer/Origin values are
accepted. Authorization/Cookie/API secrets and control-character values are
rejected. Existing validators and Range headers remain intact.

`ScopedRequestNetwork` is strongly retained, installed on main-thread plugin
registration before the map factory, refuses to replace another SDK delegate,
and leaves default platform TLS/ATS behavior intact. It supplies a nonbackground
URLSession with a TaskDelegate, never DataDelegate. A redirect leaving the
approved scope is rejected; unrelated traffic is left alone. Global additional
headers are never used. Concurrent callbacks read immutable policy.

Default is disabled at both compile and configuration levels: the experimental
network adapter and registration call require the explicit Swift build flag
`MAPLIBRE_EXPERIMENTAL_SCOPED_HEADERS`; no flag or Info.plist keys are added. A future, reviewed enablement
requires that flag, `MapLibreScopedRequestHeadersEnabled = true` and a dictionary named
`MapLibreScopedRequestHeaders` with `Host`, `PathPrefix`, and `Headers`. These
values must come from the provider's approved native-app contract. Do not copy
browser identity headers to evade a denial. Keep the Dart iOS GovMap gate until
all checks below pass. The absence of configuration does not silently pretend
that the header problem is solved.

## Validation gates

Dart helper tests cover exact bytes/escaped local path, wait ordering, remote
bypass, missing/empty file, and native callback failure. They do not run the
Objective-C bridge or native downloader.

On macOS run `tool/ios-network-tests/run-policy-tests.sh` for the Foundation
policy suite. Then build the plugin/app against the recorded SDK and verify
Swift importer names/selectors, delegate lifetime, registration order, and
custom-session compatibility. This Linux workspace has no Swift/Xcode compiler;
the Swift suite and app build are **not run** here.

Use a controlled URLProtocol/server fixture to test exact host, host suffix,
wrong scheme/port/user-info, path escape, unrelated glyph requests, conditional
requests, and same-scope/cross-scope/downgrade redirects. Verify concurrent
online/offline cancellation and no header transmission outside scope.

Then with provider-authorized settings, test one small live area and one bounded
offline pack, app restart/airplane mode, removal, interruption, and storage
pressure. Check local-file style bootstrap independently with IHM as well as
GovMap. No 401/403 workaround, proxy, custom trust handler, or ATS exception is
part of this patch. A source patch is not provider permission or proof of runtime
compatibility.

## Available verification (2026-11-01)

- All13 pure Dart iOS tests passed (6 new seed tests plus7 existing progress/context tests).
- Changed Dart manager/helper/test analyzer passed against the isolated SDK package mapping.
- A nullable NSURL argument found by the first analyzer run was fixed with an explicit failure before native work; final analyzer clean.
- `git diff --check` with existing CRLF files accounted for passed.
- Native Swift policy tests, SDK delegate integration, Xcode compile, actual pack download/reopen, and physical iPhone retention remain not run.
- Logs in workspace `tool-state/ios-network-tests.log` and `tool-state/ios-network-analyze.log`.
