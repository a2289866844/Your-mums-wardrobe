# wardrobe

[简体中文](README.zh-CN.md) · **繁體中文** · [English](../README.md) · [Français](README.fr.md) · [Deutsch](README.de.md) · [日本語](README.ja.md) · [Русский](README.ru.md)

<img src="clipline-icon.png" alt="wardrobe 圖示" width="80">

macOS 截圖與剪貼簿卡片架：收集文字、連結、圖片及檔案，複製完整內容或拖曳到其他 App。

由 **[@a2289866844](https://github.com/a2289866844)** 開發，原名 Clipline。

## 功能

**1.2 預覽版**加入歷史紀錄、中文與截圖 OCR 搜尋、釘選及文字編輯。每頁六張卡片，可瀏覽最近 120 張，更舊的資料仍可從資料庫搜尋。

**Control + Option + T** 顯示或隱藏卡片架；**Command + Shift + V** 在 1.2 開啟搜尋。也可將游標移到瀏海附近或螢幕上緣中央叫出卡片。

## 取得版本

| 版本 | 需求 | 下載 |
| --- | --- | --- |
| 1.1.6 穩定版，使用舊名 Clipline | macOS 14+ | [DMG / ZIP](https://github.com/a2289866844/Your-mums-wardrobe/releases/tag/clipline-v1.1.6) |
| 1.2 開發預覽，含歷史、搜尋與 OCR | macOS 15+、Swift 6 | [從原始碼建置](https://github.com/a2289866844/Your-mums-wardrobe/tree/codex/clipline-public-1.2)，尚無公開安裝包 |

穩定版安裝程式仍是 `Clipline.app`，不含資料庫歷史功能。它使用 ad-hoc 簽章，未經 Apple 公證。[穩定版安裝說明](https://github.com/a2289866844/Your-mums-wardrobe/blob/976a4ad/README.md) · [舊版 1.1 截圖與拖曳示範](https://github.com/a2289866844/Your-mums-wardrobe/releases/download/clipline-v1.1.3/Clipline-1.1.3-demo.mp4)

<details>
<summary>建置 1.2 預覽版</summary>

```sh
git clone --branch codex/clipline-public-1.2 https://github.com/a2289866844/Your-mums-wardrobe.git
cd Your-mums-wardrobe
swift test
scripts/build-app.sh
open build/wardrobe.app
```

</details>

歷史以 **未加密 SQLite** 儲存在 Mac。複製敏感內容前，請先關閉 **Hang copied items**。舊有加密 Clipd 資料庫須備份並使用原始金鑰，另行離線轉換。[儲存與相容性詳情](https://github.com/a2289866844/Your-mums-wardrobe/blob/codex/clipline-public-1.2/docs/reviews/clipline-clipd-integration.md)

基於 **Alejandro Buján 的 [Tendedero](https://github.com/alejandrobujan/tendedero)**，為獨立修改版。[貢獻與致謝](https://github.com/a2289866844/Your-mums-wardrobe/blob/codex/clipline-public-1.2/AUTHORS.md) · [授權](https://github.com/a2289866844/Your-mums-wardrobe/blob/codex/clipline-public-1.2/LICENSE) · [回報問題](https://github.com/a2289866844/Your-mums-wardrobe/issues)
