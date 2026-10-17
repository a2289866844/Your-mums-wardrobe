# What changed from Tendedero

Clipline is an independent modified build maintained by [@a2289866844](https://github.com/a2289866844), based on [Alejandro Buján’s Tendedero](https://github.com/alejandrobujan/tendedero) 1.0.0. The original hanging-card shelf and upstream implementation are credited to Tendedero. Clipline uses its own name and icon and does not imply upstream endorsement. The original copyright and source license remain in [LICENSE](../LICENSE).

## Clipline additions

The published **1.1.6** installer requires macOS 14+. The **1.2 development preview** requires macOS 15+; its archive features are not included in 1.1.6. This table describes Clipline’s work relative to its Tendedero starting point, not a comparison with every later upstream release.

| Area | Published Clipline 1.1.6 | Clipline 1.2 development preview | Source and evidence |
| --- | --- | --- | --- |
| Clipboard collection | Images, text, HTTP(S) links and file references join screenshots on the shelf; collection can be paused | Captures feed the ClipdCore archive | [ClipboardWatcher.swift](../Sources/Tendedero/ClipboardWatcher.swift), [ClipboardTests.swift](../Tests/TendederoTests/ClipboardTests.swift), [1.1.0 release notes](releases/1.1.0.md) |
| Copy and drag | Visible Copy controls with Copied/Retry feedback; text preserves its full contents; native file, image and URL drag representations | Full-content Copy also works on archived and searched cards | [PeggedView.swift](../Sources/Tendedero/PeggedView.swift), [GrabArea.swift](../Sources/Tendedero/GrabArea.swift), [1.1.6 release notes](releases/1.1.6.md), [Copy verification](reviews/copy-button.md) |
| History | A temporary shelf with 1–12 slots, depending on display width, restored after restart | Up to six visible cards, 120 recent cards, and search across the archive with at most 200 results per query | [Line.swift](../Sources/Tendedero/Line.swift), [ClipdLibrary.swift](../Sources/Tendedero/ClipdLibrary.swift), [HistoryTests.swift](../Tests/TendederoTests/HistoryTests.swift) |
| Finding and reusing text | Copy the complete stored contents beyond the preview | Chinese text search, screenshot OCR search, pinned items, and full-text editing that updates the search index | [LibraryToolbar.swift](../Sources/Tendedero/LibraryToolbar.swift), [TextCardEditor.swift](../Sources/Tendedero/TextCardEditor.swift), [ClipdLibraryTests.swift](../Tests/TendederoTests/ClipdLibraryTests.swift) |
| Interaction and capture recovery | Revised reveal/dismiss timing, interaction protection, screenshot readiness retries and folder-watcher recovery | Further watcher reconciliation, background image preparation, deferred durable OCR jobs and bounded thumbnail preparation | [AppDelegate.swift](../Sources/Tendedero/AppDelegate.swift), [ScreenshotWatcher.swift](../Sources/Tendedero/ScreenshotWatcher.swift), [ScreenshotWatcherRecoveryTests.swift](../Tests/TendederoTests/ScreenshotWatcherRecoveryTests.swift), [integration review](reviews/clipline-clipd-integration.md) |
| Simplification | Includes image Markup, Preview centering and screenshot-location management | Removes those features; images open in the system default app, and monitoring follows the configured screenshot folder. Idle sway and sounds remain | [current use instructions](../README.md), [integration review](reviews/clipline-clipd-integration.md) |

The 1.2 archive, text index and OCR build on **ClipdCore**, included in [Sources/ClipdCore](../Sources/ClipdCore). Clipline’s work connects that infrastructure to the hanging-card interface and its capture, browsing, editing and Copy interactions. The active archive is ordinary, unencrypted SQLite. A 120-card recent range is a display limit, not a promise to delete older archive records.

## Contributions offered upstream

These are separate from features maintained in Clipline:

- [Tendedero PR #50 — Reveal new screenshots when the line is full](https://github.com/alejandrobujan/tendedero/pull/50) was merged on October 10, 2026.
- [Tendedero PR #51 — Retry screenshot files that are not yet readable](https://github.com/alejandrobujan/tendedero/pull/51) was closed without merging. Its submission does not establish upstream adoption.

## Verification boundaries

The linked release notes and reviews record the tests and native interactions performed for their respective builds. They are historical evidence, not a guarantee for every later commit. Performance measurements in the [screenshot review](reviews/screenshot-performance.md) are uncontrolled observations, not frame-rate measurements or a universal speedup claim. Universal builds include Intel code; the recorded native acceptance ran on Apple Silicon.

The existing [13-second demo](demo.md) shows a screenshot dragged into a synthetic local chat composer using an older verification build. It does not demonstrate the 1.2 archive features or a real network upload.
