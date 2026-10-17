# Clipline

<img src="docs/clipline-icon.png" alt="Clipline icon" width="96">

**A macOS screenshot and clipboard shelf with searchable history, Chinese OCR, and pinned items.**

Developed and maintained by **[@a2289866844](https://github.com/a2289866844)**. Clipline is an independent extension of [Alejandro Buján’s Tendedero](https://github.com/alejandrobujan/tendedero), with its own name and icon. [What I added](https://github.com/a2289866844/Your-mums-wardrobe/blob/codex/clipline-public-1.2/docs/CHANGES-FROM-TENDEDERO.md) · [繁體中文](https://github.com/a2289866844/Your-mums-wardrobe/blob/codex/clipline-public-1.2/docs/README.zh-TW.md)

## Choose a version

| Version | Availability | macOS |
| --- | --- | --- |
| **1.1.6 stable** | [Download DMG or ZIP](https://github.com/a2289866844/Your-mums-wardrobe/releases/tag/clipline-v1.1.6) — screenshot/clipboard shelf and one-click Copy | 14+ |
| **1.2 developer preview** | [Source branch](https://github.com/a2289866844/Your-mums-wardrobe/tree/codex/clipline-public-1.2) — archive, search, OCR, pinned items and text editing | 15+ |

The stable installer predates the archive features described below. The preview is for testing and building from source; it has no published installer yet.

## What the preview adds

- **Find something you copied earlier.** Search saved text and recognized screenshot text, including Chinese. Search returns up to 200 matches.
- **Keep useful items close.** Pin cards, switch between History and Pinned, and browse six cards at a time. The shelf keeps up to 120 recent items; older archived items remain searchable.
- **Use the full content.** Copy complete text, URLs, images or file references; drag a card into another app. Card previews can be shorter than the copied content.
- **Edit saved text.** Open a text card, edit its contents, and save the archive entry and search index together.
- **Keep collection local.** SQLite history and image blobs stay on the Mac. The preview does not start a network-upload or knowledge-base service.

Clipboard collection, screenshot recovery, card interaction fixes and full-content Copy were added across the earlier Clipline releases. The new archive/search/OCR work builds on the included ClipdCore library. [See the contribution and evidence table](https://github.com/a2289866844/Your-mums-wardrobe/blob/codex/clipline-public-1.2/docs/CHANGES-FROM-TENDEDERO.md).

## Use Clipline

**Control + Option + T** toggles the shelf. Hover over the MacBook notch to reveal it; displays without a notch use a small centered top-edge region. Newly collected items preview for three seconds, with automatic dismissal paused while a card is held, dragged or its menu is open.

In the preview, **Command + Shift + V** opens search. Right-click a card to pin it, copy plain text or copy recognized image text. Click a text card to view or edit it. Images open in the system’s default app. The preview follows the screenshot save location already selected in macOS.

To install the **stable** build, download its DMG, drag Clipline.app into Applications, and launch it. The shared build uses an ad-hoc signature and is not notarized by Apple; [Apple’s opening instructions](https://support.apple.com/guide/mac-help/mh40616/mac) explain the macOS prompt. [Stable-version instructions](https://github.com/a2289866844/Your-mums-wardrobe/blob/976a4ad/README.md) describe its different screenshot-management and image-opening behavior.

### Local data

The preview archive uses ordinary, **unencrypted SQLite** in `~/Library/Application Support/Clipd`. An existing encrypted Clipd archive requires a separate offline conversion using its original key and a verified backup; this preview does not convert it on launch. The [conversion helper](https://github.com/a2289866844/Your-mums-wardrobe/blob/codex/clipline-public-1.2/scripts/convert-archive-to-plaintext.swift) exports to a new directory and compares records without replacing the original. Archived text and links are read from the database; image representations use local blob files. External file cards retain references to their originals.

Turn off **Hang copied items** from the menu bar to pause clipboard collection. Clipline skips protected clipboard markers, but those markers cannot identify every password or confidential item.

## Build the preview

Requires **macOS 15+ and Swift 6**, supplied by a suitable Xcode or Command Line Tools installation. ClipdCore is included in this checkout; no sibling project is required. SwiftPM resolves the pinned SQLCipher dependency.

```sh
git clone --branch codex/clipline-public-1.2 https://github.com/a2289866844/Your-mums-wardrobe.git
cd Your-mums-wardrobe
swift test
scripts/build-app.sh
open build/Clipline.app
```

`scripts/make-dmg.sh` produces a universal DMG, ZIP and SHA-256 checksum file. Builds include Apple Silicon and Intel architectures; compilation does not establish execution on physical Intel hardware.

## Demo

[![Screenshot-to-card native drag-and-drop demo](https://github.com/a2289866844/Your-mums-wardrobe/blob/codex/clipline-public-1.2/docs/media/clipline-demo.gif)](https://github.com/a2289866844/Your-mums-wardrobe/releases/download/clipline-v1.1.3/Clipline-1.1.3-demo.mp4)

The 13-second **1.1 demo** shows a real screenshot file dragged through Clipline into a local composer. It demonstrates the earlier screenshot/drag workflow, rather than the new history/search interface. It uses synthetic content and does not upload or send the file. [Demo notes](https://github.com/a2289866844/Your-mums-wardrobe/blob/codex/clipline-public-1.2/docs/demo.md).

## Contribute and share

[Report a reproducible bug](https://github.com/a2289866844/Your-mums-wardrobe/issues) with your Clipline/macOS versions and steps. Remove private clipboard contents from screenshots and recordings. Contributions and focused pull requests are welcome.

If Clipline helps your workflow, **[star the repository](https://github.com/a2289866844/Your-mums-wardrobe)** or share the demo with someone who uses a Mac. [Launch text in English and Traditional Chinese](https://github.com/a2289866844/Your-mums-wardrobe/blob/codex/clipline-public-1.2/docs/launch/announcement.md) is available for sharing.

## Attribution

Original Tendedero code and concept: **Alejandro Buján**. Clipline’s extensions and the contributed ClipdCore library: **[@a2289866844](https://github.com/a2289866844)**. Original copyright and source-license terms are preserved; the Tendedero name and artwork remain excluded from that source license. Clipline uses its own name and generated icon and is not endorsed by the original author.

[Authors](https://github.com/a2289866844/Your-mums-wardrobe/blob/codex/clipline-public-1.2/AUTHORS.md) · [License](https://github.com/a2289866844/Your-mums-wardrobe/blob/codex/clipline-public-1.2/LICENSE) · [Notices](https://github.com/a2289866844/Your-mums-wardrobe/blob/codex/clipline-public-1.2/NOTICE.md) · [SQLCipher license](https://github.com/a2289866844/Your-mums-wardrobe/blob/codex/clipline-public-1.2/ThirdPartyLicenses/SQLCipher-LICENSE.md)
