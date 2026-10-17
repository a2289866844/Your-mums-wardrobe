# Clipline 1.2 developer preview: architecture and verification

This publication combines the maintainer’s Clipline 1.2 source and the ClipdCore library in one checkout. It is a source preview, separate from the published 1.1.6 installer. It requires macOS 15 and a Swift 6 toolchain.

## Responsibilities and data flow

| Component | Responsibility |
| --- | --- |
| `AppDelegate`, `ScreenshotWatcher`, `ClipboardWatcher` | Watch the selected screenshot folder and clipboard; reveal the native shelf and protect active interactions |
| `ClipboardPreparation`, `ScreenshotThumbnailLoader` | Prepare immutable image data, fingerprints and thumbnails away from the main actor |
| `Line`, `LineView`, `PeggedView`, `GrabArea` | Keep card state, six-card navigation, full-content Copy and native drag representations |
| `ClipdLibrary`, `LibraryToolbar`, `TextCardEditor` | Connect captured cards to history, search, pinning and text editing; publish results on the main actor |
| `ClipdCore.Store`, `TextIndex` | Serialize SQLite access, preserve representations and maintain Chinese-search indexes |
| `CaptureCoordinator`, `OCRService` | Persist image representations and recognize text for archive search |

Capture enters through a watcher, prepares a card, then commits archive data. Startup and search read metadata before preparing the active page’s images. New captures merge with history without replacing their live identity. The recent range contains up to 120 cards, displayed six at a time; search reads the archive and shows at most 200 matches. Evicting an old recent card does not delete its archive entry.

Image normalization runs on a serial background worker. Thumbnails use a preparation window of at most 20 cards and an NSCache cost limit of 64 MiB. Superseded queued searches are cancelled before database work, and results are checked before publication.

Image persistence does not wait for OCR: the record and durable `image_ocr_jobs` entry commit together. Recognition starts after the shelf retracts and a 350 ms idle delay, one job at a time, with at most three attempts across launches. Recognition updates the search text/index and removes the job together; it preserves pins and representations and does not recreate deleted items.

## Local storage and compatibility

The default archive directory is `~/Library/Application Support/Clipd`. The preview opens ordinary, unencrypted SQLite, with local image blobs and references to external originals. Existing encrypted Clipd archives require a separate offline conversion using the original key and a verified backup. The [conversion helper](../../scripts/convert-archive-to-plaintext.swift) exports into a new directory and compares records; it does not replace the original or run automatically at launch.

The ClipdCore sources are compiled as a local SwiftPM target. The separate Clipd application, compatibility launcher, personal clipboard records, keys and local backups are not part of this publication. SQLCipher 4.17.0 is pinned and its supplied license is included in the app and installer. The archive is unencrypted despite the dependency’s name.

## User-facing scope

History, Chinese/OCR search, pins, text editing, full-content Copy, drag, automatic reveal/retract, idle sway and sounds remain. Image Markup, Preview-window centering, screenshot-location takeover, sequential copying and abbreviation expansion are absent from this preview. Images open in the system default application; the watcher follows the macOS screenshot folder. Upload/knowledge-base services and automatic retention sweeps are not started by the integration.

## Verification for this publication

Fresh verification on October 16, 2026 used this self-contained checkout:

- `swift test` passed **179 Clipline XCTest tests** and **253 ClipdCore Swift Testing tests**, with zero failures.
- `scripts/build-app.sh` built the production executable and embedded SQLCipher framework for **arm64 and x86_64**.
- `codesign --verify --deep --strict` passed for the app and its embedded framework. The app includes the SQLCipher license notice.
- A native isolated fixture linked this checkout’s production source and exercised six-card browsing, Chinese search, an empty-result query, and the Pinned scope. Its real Copy control returned all **779 characters** of an archived text card and the private own-copy marker. The fixture used a private archive, folder, pasteboard and preferences.
- The source publication excludes build products, personal archive files and keys. Credential-pattern findings in the added tests were detector/redaction fixtures, not imported credentials.

These checks establish compilation and automated regression coverage. They do not establish physical Intel execution, notarization, screenshot permission on another Mac, or every display, Space and drag destination. The packaged app has not replaced the installed app as part of publication.

The [screenshot performance report](screenshot-performance.md) records historical build-17 observations. Its uncontrolled measurements are not an FPS guarantee or a controlled percentage improvement claim. The [existing 13-second demo](../demo.md) shows the older screenshot/drag workflow; it does not show the new archive interface.
