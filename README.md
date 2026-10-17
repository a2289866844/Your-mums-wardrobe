# wardrobe

[简体中文](docs/README.zh-CN.md) · [繁體中文](docs/README.zh-TW.md) · **English** · [Français](docs/README.fr.md) · [Deutsch](docs/README.de.md) · [日本語](docs/README.ja.md) · [Русский](docs/README.ru.md)

<img src="docs/clipline-icon.png" alt="wardrobe icon" width="80">

A macOS shelf for screenshots and copied text, links, images and files. Copy the full content or drag a card into another app.

Developed by **[@a2289866844](https://github.com/a2289866844)**. Previously named Clipline.

## Features

The **1.2 preview** adds searchable history, Chinese and screenshot OCR search, pinned cards, and text editing. Browse six cards at a time, with up to 120 recent items; older archived items remain searchable.

**Control + Option + T** toggles the shelf. **Command + Shift + V** opens search in 1.2. Hover near the notch or top-center edge to reveal cards.

## Get it

| Version | Requirements | Download |
| --- | --- | --- |
| 1.1.6 stable — legacy Clipline name | macOS 14+ | [DMG / ZIP](https://github.com/a2289866844/Your-mums-wardrobe/releases/tag/clipline-v1.1.6) |
| 1.2 developer preview — history, search and OCR | macOS 15+, Swift 6 | [Build from source](https://github.com/a2289866844/Your-mums-wardrobe/tree/codex/clipline-public-1.2); no published installer yet |

The stable installer is still `Clipline.app` and predates the archive features. It uses an ad-hoc signature and is not notarized by Apple. [Stable install guide](https://github.com/a2289866844/Your-mums-wardrobe/blob/976a4ad/README.md) · [Earlier 1.1 screenshot/drag demo](https://github.com/a2289866844/Your-mums-wardrobe/releases/download/clipline-v1.1.3/Clipline-1.1.3-demo.mp4)

<details>
<summary>Build the 1.2 preview</summary>

```sh
git clone --branch codex/clipline-public-1.2 https://github.com/a2289866844/Your-mums-wardrobe.git
cd Your-mums-wardrobe
swift test
scripts/build-app.sh
open build/wardrobe.app
```

</details>

History stays on the Mac in **unencrypted SQLite**. Pause **Hang copied items** before copying sensitive content. Existing encrypted Clipd archives require separate offline conversion with the original key and a backup. [Storage and compatibility details](https://github.com/a2289866844/Your-mums-wardrobe/blob/codex/clipline-public-1.2/docs/reviews/clipline-clipd-integration.md)

Based on **[Tendedero](https://github.com/alejandrobujan/tendedero) by Alejandro Buján**. Independent modified application. [Contributions and credits](https://github.com/a2289866844/Your-mums-wardrobe/blob/codex/clipline-public-1.2/AUTHORS.md) · [License](https://github.com/a2289866844/Your-mums-wardrobe/blob/codex/clipline-public-1.2/LICENSE) · [Report an issue](https://github.com/a2289866844/Your-mums-wardrobe/issues)
