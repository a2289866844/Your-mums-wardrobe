# Clipboard image preparation

The GitHub `personal` baseline (`976a4ad`, Clipline 1.1.6) normalizes clipboard images in `ClipboardWatcher` and again in `Line`, with candidate hashing, generated-file writes and thumbnails on the main thread. Large copies can therefore delay the shelf's input and animation work.

## Change

- Snapshot immutable clipboard bytes on the main actor, retaining private-marker and `changeCount` checks. Source-item declarations distinguish supplied formats from AppKit's automatically advertised conversions; do not request an undeclared TIFF/text representation merely because it can be synthesized.
- Prepare images and file thumbnails on one serial background worker. Normalize each incoming representation once, reuse version-validated candidate digests, and pass the prepared digest to storage without hashing it again.
- Retain image-format alternatives and explicit text fallback when an image representation is malformed.
- Publish cards on the main actor in capture order, including retries when a duplicate candidate disappears. Pausing collection cancels pending publications, including reentrant callbacks and multi-file captures.
- Protect Finder originals and upgrade existing card references before yielding. Validate file revisions across preparation and before publication. Existing ownership, symlink, drag/edit and clipboard-lease protections remain in effect.
- Refresh edited-image thumbnails on the worker. Direct synchronous model ingestion remains available for deterministic callers; production capture uses the background entry point.

This branch is isolated from the later, uncommitted local 1.2 development checkout. It does not replace the installed app or publish a release.

## Local synthetic measurement

Both binaries use `swiftc -O` on the same Apple Silicon Mac. The fixture places one synthetic PNG on a private pasteboard, calls the actual `ClipboardWatcher.poll()` path, and checks that one image card is eventually added. Three fresh Line/storage instances are used per image size. Initialization and fixture generation are outside the measured interval.

| Image | Baseline main-thread call | Background main-thread call | Background completion |
| --- | --- | --- | --- |
| 1200 × 900 | 21.73–61.92 ms | 0.17–0.73 ms | 15.77–36.48 ms |
| 4000 × 3000 | 230.75–327.66 ms | 0.19–0.27 ms | 122.74–149.76 ms |

The improvement is in synchronous main-thread occupancy, not an equivalent speedup in all image processing. Background completion still takes time. These are three local synthetic observations with other desktop activity uncontrolled; they are not FPS, input-latency guarantees, or evidence that every clipboard provider is fast. Reading lazily provided pasteboard bytes, file metadata, icons and an explicitly initiated image Copy can still perform synchronous work.

Raw observations: [clipboard-image-benchmark.json](evidence/clipboard-image-benchmark.json).

The reproducible harness is [scripts/benchmarks/clipboard-images.swift](../../scripts/benchmarks/clipboard-images.swift). Compile it with the runtime sources except `main.swift`; define `OPTIMIZED` for this branch. For a baseline comparison, compile the same harness against the original commit without that define. Run the binaries sequentially rather than concurrently.

```sh
xcrun swiftc -O -DOPTIMIZED -parse-as-library -module-name Tendedero \
  $(rg --files Sources/Tendedero -g '*.swift' | rg -v '/main.swift$') \
  scripts/benchmarks/clipboard-images.swift -o /tmp/clipline-image-benchmark
/tmp/clipline-image-benchmark
```

## Validation

- Full regression suite: 157 tests, zero failures, including 18 new preparation/snapshot/order/cancellation/ownership tests.
- Universal arm64/x86_64 production build and strict code-signature verification.
- Isolated native fixture: the real AppDelegate/ClipboardWatcher/background Line path received a synthetic 4000×3000 PNG from a private pasteboard; a hosted production PeggedView showed the resulting card. Clicking its actual Copy button changed the label to Copied. Readback reported PNG data, own-copy marker, success and no failure; the managed PNG retained 4000×3000 dimensions and the shelf remained at one card.
- The fixture uses private preferences, pasteboard and storage. The installed app and personal clipboard/archive are outside this verification.

The tests exercise controlled providers and callbacks. A fresh OS screenshot shortcut, all external drag destinations, physical Intel execution and every lazy-provider behavior were not revalidated here.
