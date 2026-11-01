# Android SDK pin provenance

The Android dependency is pinned to `org.maplibre.gl:android-sdk:12.3.1`.
This replaces the floating `12.3.+` selector with the **same artifact already
resolved and compiled**, not a library upgrade. No Dart/native API implementation,
iOS dependency, header, networking policy, or other dependency changes accompany
this pin.

## Existing verification evidence

The guarded Android arm64 profile API probe compiled native fork
`44aa2ea556e2242b7e09fc3cbdd1e1af613ae478`, using the separate app checkout at
`bc10fb56752d6f33e63b25fe9bfdaaf105f264c2` and isolated MapLibre path overrides.
The probe was never installed or launched.

- `tool-state/native-offline-probe-build.log`, line 4332 (and manifest-merger
  entries nearby), records `org.maplibre.gl:android-sdk:12.3.1` and the transformed
  `jetified-android-sdk-12.3.1/AndroidManifest.xml`.
- Cached Maven POM explicitly identifies group `org.maplibre.gl`, artifact
  `android-sdk`, version `12.3.1`, packaging `aar`.
- Cached original artifact: `android-sdk-12.3.1.aar`.
- AAR SHA-256:
  `95258a1e4f5abb53892b99b4960e156a27a8465bc5a6347fca6e897cd4c3e7e7`.
- The successful probe APK SHA-256:
  `9b46fc91f09334c2aceee74eb774096912a33814fbce6e0b6cc73cdb79f775d1`.
- Probe metadata/override hashes are retained in
  `tool-state/native-offline-probe-evidence.txt` in the validation workspace.

Only static cache/log inspection was performed for this pin. No additional
Gradle invocation or build was run for the metadata-only change. The earlier
compile verifies the selected SDK artifact; it does not constitute native device
or provider-fetch verification. **Do not describe SDK 12.3.0 as tested.**
