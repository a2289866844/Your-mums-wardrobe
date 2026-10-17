# Screenshot performance — local 1.2.0 build 17

On 2026-10-16 the user reported several seconds of desktop stutter after each screenshot. The historical build-17 measurements below ran on the maintainer’s Apple Silicon Mac. The public preview includes later build-20 changes; see [current integration and verification](clipline-clipd-integration.md).

Screenshot arrival now uses the shelf's existing thumbnail and a short, damped card entrance. It no longer creates the full-screen capture-flight panel or decodes a second image of up to 3,000 pixels on the main actor. Capture metadata still selects the appropriate display. The idle breeze and sounds retain their existing paths.

Clipline opts into `OCRService(avoidsGPU: true)` for new images and image reindexing. Each supported Vision compute stage selects a supported Neural Engine device first, then a supported CPU device. Accurate recognition, Chinese-first language ordering, small-text retry and reading-order reconstruction remain in use. The shared ClipdCore service retains its default configuration for existing callers. Device assignment follows Apple's [VisionRequest API](https://developer.apple.com/documentation/vision/visionrequest/setcomputedevice%28_%3Afor%3A%29).

## Observed load

The installed production app received three uniquely hashed copies of the supplied PNG through its real screenshot folder. Each copy carried the same capture rectangle and reached the archive with 579 OCR characters. These were file-arrival probes, not fresh macOS screen captures.

Each trial targeted a 10-second observation window, with the file arriving after approximately one second. `/usr/bin/sample` sampled Clipline at 5 ms; process counters came from `ps`. CPU seconds below are cumulative process CPU-time differences across each observation window, including idle time and unrelated desktop activity. Peak CPU is the maximum value reported by `ps`, not a frame-rate measurement.

| Metric | Original build 15 | Intermediate build 16 | Final build 17 |
| --- | ---: | ---: | ---: |
| Clipline CPU seconds | 2.30 | 2.27 | 0.96 |
| Clipline peak CPU | 108.1% | 96.9% | 46.8% |
| WindowServer CPU seconds | 5.97 | 4.98 | 2.64 |
| WindowServer peak CPU | 104.7% | 90.7% | 69.6% |
| fseventsd CPU seconds | 10.09 | 13.22 | 6.70 |

The first change reduced WindowServer work but barely changed Clipline's CPU time. The final change also shortened the new-card spring, which otherwise continued recompositing glass and shadows for several seconds. The final native screenshot showed the new card and existing controls, and the capture-flight path did not appear in the final sample.

There was one trial per configuration, other computer activity was not controlled, and fseventsd's load also changed. The figures show lower observed load; they do not establish a controlled percentage improvement or prove that all desktop frame drops are gone. The attempted macOS screenshot shortcut did not create a new capture through CUA, so feedback from the user's normal screenshot shortcut remains necessary.

Separately, fseventsd used about 10–13 GiB RSS during the trials, with substantial CPU use even outside capture processing. Its cause is undiagnosed: sampling that system process required privileges unavailable in this session. No service restart or system-setting change was performed.

## Validation and preservation

- The full Clipline suite passed 179 tests after the screenshot and OCR changes. After the final entrance-animation edit, all 9 selected screenshot-arrival, hosted Copy and capture-geometry tests passed again.
- All 13 ClipdCore OCR tests passed, including a new non-GPU mixed Chinese/English recognition and reading-order regression.
- Universal arm64/x86_64 production build and strict nested code-signature verification passed. The installed executable's SHA-256 matches the verified build. Runtime acceptance was on Apple Silicon; the Intel CPU fallback was compiled but not exercised on an Intel Mac.
- The final running process retained an open directory handle to the configured screenshot directory and an open archive. All three capture probes were archived with OCR text.
- Compared the original 11,443 `items`, 62,461 `item_reps` and 11,443 `item_rowid` rows in full against a consistent final SQLite snapshot. Zero original rows were missing or changed. No image files were created during either application-replacement interval.
- Existing working-tree changes in both repositories were retained. That historical checkout depended on an adjacent `clipd` package. The public preview includes the required ClipdCore sources in this repository.

Local evidence, the original app backup, protected SQLite snapshots, a focused production-source patch, test/build logs and `final-native.png` are in `build/screenshot-performance-20261016/`. That directory is accessible only to the current account. `comparison.json` and `final-validation.json` contain the measured values and preservation results without clipboard contents.
