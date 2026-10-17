# wardrobe

[简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [English](../README.md) · [Français](README.fr.md) · [Deutsch](README.de.md) · **日本語** · [Русский](README.ru.md)

<img src="clipline-icon.png" alt="wardrobe のアイコン" width="80">

スクリーンショットやコピーしたテキスト、リンク、画像、ファイルを置ける macOS 用のシェルフです。内容を丸ごとコピーしたり、カードを別のアプリにドラッグしたりできます。

開発者：**[@a2289866844](https://github.com/a2289866844)**。旧名は Clipline です。

## 機能

**1.2 プレビュー版**では、履歴検索、中国語やスクリーンショット内の文字の OCR 検索、カードのピン留め、テキスト編集が加わりました。最近の項目を最大 120 件、6 枚ずつ表示できます。アーカイブされた古い項目も検索できます。

**Control + Option + T** でシェルフの表示を切り替えます。1.2 では **Command + Shift + V** で検索を開けます。ノッチ付近や画面上端の中央にポインタを合わせるとカードが現れます。

## 入手方法

| バージョン | 動作要件 | ダウンロード |
| --- | --- | --- |
| 1.1.6 安定版 — 旧名 Clipline | macOS 14+ | [DMG / ZIP](https://github.com/a2289866844/Your-mums-wardrobe/releases/tag/clipline-v1.1.6) |
| 1.2 開発者プレビュー版 — 履歴・検索・OCR | macOS 15+、Swift 6 | [ソースからビルド](https://github.com/a2289866844/Your-mums-wardrobe/tree/codex/clipline-public-1.2)（インストーラは未公開） |

安定版のアプリ名は引き続き `Clipline.app` で、アーカイブ機能の追加前のバージョンです。アドホック署名を使用しており、Apple の公証は受けていません。[安定版のインストールガイド](https://github.com/a2289866844/Your-mums-wardrobe/blob/976a4ad/README.md) · [旧 1.1 のスクリーンショット・ドラッグ操作デモ](https://github.com/a2289866844/Your-mums-wardrobe/releases/download/clipline-v1.1.3/Clipline-1.1.3-demo.mp4)

<details>
<summary>1.2 プレビュー版をビルドする</summary>

```sh
git clone --branch codex/clipline-public-1.2 https://github.com/a2289866844/Your-mums-wardrobe.git
cd Your-mums-wardrobe
swift test
scripts/build-app.sh
open build/wardrobe.app
```

</details>

履歴は Mac 内の**暗号化されていない SQLite** に保存されます。機密情報をコピーする前に **Hang copied items** を一時停止してください。既存の暗号化された Clipd アーカイブには、元の鍵とバックアップを用いた別途のオフライン変換が必要です。[保存形式と互換性の詳細](https://github.com/a2289866844/Your-mums-wardrobe/blob/codex/clipline-public-1.2/docs/reviews/clipline-clipd-integration.md)

**Alejandro Buján 作の [Tendedero](https://github.com/alejandrobujan/tendedero)** を基にした、独立した改変アプリです。[貢献者とクレジット](https://github.com/a2289866844/Your-mums-wardrobe/blob/codex/clipline-public-1.2/AUTHORS.md) · [ライセンス](https://github.com/a2289866844/Your-mums-wardrobe/blob/codex/clipline-public-1.2/LICENSE) · [問題を報告](https://github.com/a2289866844/Your-mums-wardrobe/issues)
