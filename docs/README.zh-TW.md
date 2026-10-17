# wardrobe

wardrobe（原名 Clipline）是由 [@a2289866844](https://github.com/a2289866844) 維護的 macOS 截圖與剪貼簿卡片架，基於 [Alejandro Buján 的 Tendedero](https://github.com/alejandrobujan/tendedero) 1.0.0，使用獨立名稱與圖示。它讓你從螢幕上方叫出卡片，複製完整內容，或拖曳到其他 App。

[English README](../README.md) · [相對於 Tendedero 的改動](CHANGES-FROM-TENDEDERO.md) · [問題回報](https://github.com/a2289866844/Your-mums-wardrobe/issues)

## 選擇版本

| | 已發布 1.1.6 | 1.2 開發預覽 |
| --- | --- | --- |
| 系統 | macOS 14 以上 | macOS 15 以上 |
| 內容 | 截圖、複製的圖片、文字、連結與檔案；可直接複製或拖曳 | 加入 ClipdCore 本機資料庫、中文與截圖 OCR 搜尋、釘選及全文編輯 |
| 歷史 | 依螢幕寬度保留 1–12 張暫存卡片，重新啟動後還原 | 每頁最多六張、最近 120 張；搜尋完整資料庫，每次最多顯示 200 筆 |
| 取得方式 | [下載 1.1.6](https://github.com/a2289866844/Your-mums-wardrobe/releases/tag/clipline-v1.1.6) | 從 `codex/clipline-public-1.2` 分支建置；屬於開發預覽 |

1.1.6 安裝程式**不包含** 1.2 的資料庫整合。1.2 的資料庫是未加密的 SQLite，存放在 `~/Library/Application Support/Clipd`；正常使用不需要金鑰。最近 120 張的限制不會因卡片被擠出而刪除較舊的資料庫紀錄。

## 安裝已發布版本

1. 下載舊版 `Clipline-1.1.6-universal.dmg`，將仍以原名發布的 `Clipline.app` 拖到「應用程式」。
2. 開啟舊版 Clipline。若 macOS 阻擋，前往「系統設定 → 隱私權與安全性」，找到提示後選擇「強制打開」。此版本使用 ad-hoc 簽章，未經 Apple 公證。
3. 系統詢問時，允許存取截圖資料夾。選單列的迴紋針是 Clipline。

1.1.6 可能在首次設定時調整 Desktop 截圖目的地，並提供截圖管理功能；詳見其[版本說明](releases/1.1.6.md)與[1.1.6 英文使用說明](https://github.com/a2289866844/Your-mums-wardrobe/blob/976a4ad/README.md)。1.2 已移除截圖接管，會跟隨 macOS 已設定的截圖資料夾。

## 使用 1.2 開發預覽

- **Control + Option + T**：顯示或隱藏卡片架。**Command + Shift + V**：開啟搜尋。
- 點卡片的 **Copy** 複製完整內容；成功時顯示 **Copied**，失敗時可按 **Retry**。文字預覽被截短，不影響完整複製。
- 用左右箭頭瀏覽較舊或較新的卡片；新內容不會打斷正在瀏覽的歷史頁面。
- 切換歷史與釘選，或搜尋中文文字及已辨識的圖片文字。OCR 在背景處理，剛加入的圖片可能尚未能以文字搜尋。
- 點文字卡片查看或編輯全文；右鍵可釘選或複製純文字／圖片辨識文字。圖片使用系統預設 App 開啟。
- 將卡片拖到其他 App。文字保留全文、連結保留 URL；圖片與檔案以檔案格式提供。接收端若選擇移動檔案，完成後卡片會從架上移除。

新內容閒置時會預覽約三秒；拖曳、按住卡片或操作選單會延後關閉。也可從瀏海附近的上緣叫出卡片架。卡片的擺動與音效仍保留。

剪貼簿收集預設啟用，可在選單列關閉 **Hang copied items**。程式會略過帶有受保護標記的剪貼簿內容，但無法辨認所有機密資料；複製敏感內容前請暫停收集。

## 從原始碼建置 1.2

需要 macOS 15 以上及 **Swift 6** 工具鏈，可由 Xcode 或 Command Line Tools 提供。此原始碼包含 ClipdCore；Swift Package Manager 會取得 SQLCipher 相依套件。

```sh
git clone --branch codex/clipline-public-1.2 https://github.com/a2289866844/Your-mums-wardrobe.git
cd Your-mums-wardrobe
swift test
scripts/build-app.sh
open build/wardrobe.app
```

`scripts/make-dmg.sh` 會產生 `wardrobe-1.2.0-universal.dmg`、`wardrobe-1.2.0-universal.zip` 與 SHA-256 校驗檔。測試與建置不代表所有螢幕、全螢幕 App 或拖曳目的地都已人工驗證；詳見[整合紀錄](reviews/clipline-clipd-integration.md)。

## 致謝與授權

原始卡片架與上游實作來自 Alejandro Buján 的 Tendedero。wardrobe 的剪貼簿、互動、可靠性與資料庫整合改動由 @a2289866844 維護；資料庫、文字索引及 OCR 基於 ClipdCore。原始 MIT 授權與作者聲明保留於 [LICENSE](../LICENSE)。wardrobe 是獨立修改版，不代表上游作者背書。
