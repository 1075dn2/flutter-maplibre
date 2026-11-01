/// Whether a native offline snapshot proves complete, precise resource coverage.
///
/// Resource counts include styles, glyphs and sprites, not just map tiles.
/// A lower-bound expected count must never be treated as completion.
bool hasCompleteOfflineResources({
  required bool nativeComplete,
  required int completedResources,
  required int requiredResources,
  required int maximumRequiredResources,
}) =>
    nativeComplete &&
    completedResources > 0 &&
    maximumRequiredResources == requiredResources &&
    completedResources >= requiredResources;
