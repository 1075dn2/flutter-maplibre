# Fixed Varela v1 offline seeds — disabled integration

This branch adds an optional `bundledGlyphSeeds` parameter to `downloadRegion`.
Existing callers omit it and retain their original remote-font behavior. No
production app call site or dependency path is changed here.

```dart
final seeds = BundledGlyphSeeds.varelaV1(
  glyphTemplate: appOwnedBundle.glyphTemplate,
  resources: await appOwnedBundle.verifiedResourceBytes(),
);
// manager.downloadRegion(..., bundledGlyphSeeds: seeds)
```

## Trust boundary

Only the compiled 512-resource Varela Round Regular + Open Sans Bold bundle is
accepted. Each resource has a compiled SHA-256/size pin. Caller hashes and
manifests cannot extend this registry. The factory copies all bytes and exposes
a deeply immutable map. Limits: 256 KiB/resource, 1 MiB total, exactly 512 keys.

Glyph URLs must be local file URLs under `map-fonts/varela-v1-<manifest digest>/`
with exact manifest relative names and canonical URI escaping. Remote hosts,
queries, fragments, dot traversal and encoded separators are rejected. No glyph
path is read or written by this API: bytes only enter the native database. The
app remains responsible for deriving its trusted support directory, rejecting
symlinks, verifying installed bytes, retaining files for renderer use, and
validating the whole saved style including all font-expression overrides.
The original local style must name the exact supplied glyph template before
any glyph or style resource insertion is allowed.

## Ordering and lifetime

Android enqueues all bounded glyph inserts, then the existing style insertion,
then region creation on the same native manager/database actor. Its void seed
API has no persistence acknowledgment. Only actual native resource progress and
completion can establish Ready. Cancellation gates stop preparation; existing
creation timeout/late callback handling prevents late activation.

iOS awaits serial callback-bearing preloads with an overall 20-second preparation
deadline and existing per-preload 10-second bound. At most one glyph preload is
outstanding. Cancellation stops subsequent writes and pack creation; timed-out
callbacks remain retained until native acknowledgement. No timer reports Ready.

Seeding ambient resources is not a durability guarantee. Native offline download
must consume and associate the necessary glyph resources with its region. The
renderer still needs retained installed files. Cache clearing/reopening and URL
encoding require device verification on both platforms.

## Reproducible pins

Run from this fork (Python only):

```
python tool/generate_bundled_glyph_pins.py ../varela-map-font-worktree/assets/map_fonts/varela-v1 --check
```

Without `--check`, derives pins and compressed licensed test fixture from the
same app manifest. The script refuses a manifest whose digest differs from the
explicit compiled digest; changing versions requires deliberate review of app
and adapter together. It verifies every resource before writing. No network.

## Verification boundary

Python manifest/pin/fixture reproduction passes. Focused Dart tests cover exact
bytes, immutability, invalid paths/digests/sizes, ordering, mismatch before side
effects, iOS cancellation and late callback timeout. Focused SDK tests pass: 28 tests across bundled glyph preparation, existing
style seeding, and native download lifecycle. Targeted Dart analysis of all
changed production implementations plus the new test reports no issues.
The formatting tool reports the pre-existing unavailable optional
`very_good_analysis` package include; no network fetch was attempted. Native
device rendering/durability and iOS container relocation remain enablement
blockers, not passed tests.
