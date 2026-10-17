# Announcement drafts

Draft copy for @a2289866844 to publish or adapt. These drafts have not been posted. The links distinguish the published 1.1.6 installer from the 1.2 development preview.

## English

I’ve been developing **Clipline**, my independent macOS screenshot and clipboard shelf based on Alejandro Buján’s open-source Tendedero 1.0.0.

My changes add clipboard collection, visible Copy buttons with success/retry feedback, full-content text copying and dragging, and fixes for screenshot recovery and shelf interactions. The published **1.1.6** build is available for macOS 14+.

The **1.2 development preview** goes further: it connects the hanging-card shelf to ClipdCore’s local SQLite archive, with Chinese and screenshot OCR search, pinned items, and editable text history. You can browse up to six cards per page, keep 120 recent cards available, and search older archive entries. It requires macOS 15+ and is separate from the 1.1.6 installer.

I’ve also simplified this preview: images open in the system default app, screenshot monitoring follows the configured folder, and the cards keep their sway and sounds. The archive is stored locally in ordinary, unencrypted SQLite.

Credit to Alejandro Buján for the original Tendedero shelf and to ClipdCore for the archive, text index and OCR infrastructure. Clipline’s extensions and integration are maintained by me, @a2289866844. One of my upstream fixes—revealing a new screenshot when the shelf is full—was accepted as [Tendedero PR #50](https://github.com/alejandrobujan/tendedero/pull/50).

- [Source and development preview](https://github.com/a2289866844/Your-mums-wardrobe/tree/codex/clipline-public-1.2)
- [Published 1.1.6 installer](https://github.com/a2289866844/Your-mums-wardrobe/releases/tag/clipline-v1.1.6)
- [What I changed from Tendedero](https://github.com/a2289866844/Your-mums-wardrobe/blob/codex/clipline-public-1.2/docs/CHANGES-FROM-TENDEDERO.md)

If you try it, I’d appreciate feedback on screenshot arrival, searching Chinese text, and copying full text from older cards. Please include your macOS and Clipline versions in bug reports.

## 繁體中文

最近我持續開發了 **Clipline**：一個 macOS 截圖與剪貼簿卡片架，基於 Alejandro Buján 的開源專案 Tendedero 1.0.0，是使用獨立名稱與圖示的修改版。

我加入了剪貼簿收集、帶有成功／重試回饋的 Copy 按鈕、完整文字複製與拖曳，並修正截圖監測恢復與卡片架互動。已發布的 **1.1.6** 支援 macOS 14 以上。

這次的 **1.2 開發預覽**，把卡片架接上 ClipdCore 的本機 SQLite 資料庫，加入中文與截圖 OCR 搜尋、釘選，以及可編輯的文字歷史。每頁最多六張卡片、可瀏覽最近 120 張，也能搜尋更舊的資料庫內容。預覽版需要 macOS 15 以上，與目前的 1.1.6 安裝程式不同。

我也做了簡化：圖片交給系統預設 App 開啟，截圖監測跟隨目前設定的資料夾，保留卡片擺動與音效。歷史資料保存在本機，使用未加密的 SQLite。

原始 Tendedero 卡片架的設計與上游實作歸功於 Alejandro Buján；資料庫、文字索引與 OCR 基於 ClipdCore。Clipline 的擴充與整合由我 **@a2289866844** 維護。我提交的「卡片架已滿時仍顯示新截圖」修正，也已透過 [Tendedero PR #50](https://github.com/alejandrobujan/tendedero/pull/50) 合併到上游。

- [原始碼與開發預覽](https://github.com/a2289866844/Your-mums-wardrobe/tree/codex/clipline-public-1.2)
- [已發布 1.1.6 安裝程式](https://github.com/a2289866844/Your-mums-wardrobe/releases/tag/clipline-v1.1.6)
- [相對於 Tendedero，我做了哪些改動](https://github.com/a2289866844/Your-mums-wardrobe/blob/codex/clipline-public-1.2/docs/CHANGES-FROM-TENDEDERO.md)

歡迎試用後回報截圖出現、中文搜尋，以及舊卡片全文複製的體驗。回報問題時，請附上 macOS 與 Clipline 版本。
