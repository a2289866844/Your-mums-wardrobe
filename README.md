# Clipline

<img src="docs/clipline-icon.png" alt="Clipline 圖示" width="96">

我的 macOS 截圖與剪貼簿浮層定制版，基於 [Alejandro Buján 的 Tendedero](https://github.com/alejandrobujan/tendedero) 1.0.0。Clipline 是獨立改版，使用自己的名稱和圖示。

**[下載安裝包](https://github.com/a2289866844/clipline/releases/latest)** · macOS 14 或更新版本 · Apple Silicon / Intel 通用版

## 安裝與使用

1. 在 Releases 下載 `Clipline-1.1.0-universal.dmg`。
2. 打開磁碟映像，把 `Clipline.app` 拖到 `Applications`，再啟動。
3. 如果 macOS 阻擋開啟，到「系統設定 → 隱私權與安全性」，找到 Clipline 的提示並按「強制打開 / Open Anyway」。這個分享版採用 ad-hoc 簽章，未經 Apple 公證；[Apple 開啟說明](https://support.apple.com/guide/mac-help/mh40616/mac)。
4. 依 macOS 提示允許存取截圖所在資料夾。頂端選單列的迴紋針是 Clipline。

按 **Control + Option + T** 顯示或隱藏浮層。**單擊卡片開啟內容**；要複製，請按右鍵選 **Copy**。拖到其他 App 可分享：圖片與檔案以檔案傳遞，文字以完整文字傳遞，連結以 URL 傳遞。文字卡片只顯示摘要，複製與拖曳保留全文。圖片或檔案拖到資料夾時，目的地可選擇移動；完成移動後卡片從浮層移除。

1.1.0 的 **Hang copied items** 預設開啟，會將新複製的圖片、文字、HTTP(S) 連結與檔案放到浮層；可在選單列隨時關閉，暫停收集。Clipline 會略過帶有受保護剪貼簿標記的內容，但無法辨識所有密碼或機密資料；複製敏感內容前可先暫停。浮層內容在本機保存並於重啟後還原；由剪貼簿產生的圖片、文字和連結存於 `~/Library/Application Support/Clipline/Clipboard`，外部檔案卡片則保留原檔案參照。

這是有限容量的暫存架：依螢幕寬度提供 **3–12 個位置**，滿載時最舊卡片會掉落，並非無限剪貼簿歷史。卡片高度一致；圖片完整縮放到卡片內，保留比例而不裁切。

初次啟動會詢問是否接管截圖儲存位置，你可以選擇「Not now」。

啟用 **Handle screenshots** 會把新截圖存到 `~/Library/Application Support/Clipline/Screenshots`，並關閉 macOS 浮動縮圖；關閉該選項或正常退出時恢復先前設定。接管模式下，圖片角落的叉會將其檔案送到垃圾桶。請避免和其他會接管截圖設定的工具同時啟用這項功能。

## 這個版本的操作規則

- 熱區停留約 **0.08 秒**即可召喚，彈出動畫更快，熱區也稍微放寬。
- 滑鼠召喚後，在該螢幕的**整個頂部三分之一**範圍內保持顯示；離開便收起。
- **新截圖或剪貼簿內容無人操作時顯示 3 秒**，下一項新內容重新計時；按住卡片、拖曳或開啟右鍵選單時延後收起，等操作結束再處理。滑鼠停在熱區時，收起後需要先移開才能再次召喚。
- 快捷鍵或選單手動召喚會保持開啟，滑鼠進入浮層再離開後，等待 **5 秒**收起。
- 切換 App 或桌面不重置收起倒數，支援全螢幕 Space。
- 圖片卡片加大，並修正頂部邊界反覆彈出與收起的問題。長按圖片可開啟 Markup；其他類型沒有長按操作。
- 修正截圖列滿載時新截圖不自動顯示、重啟時列表被截短，以及未寫完的圖片被永久漏掉等問題。

## 從原始碼構建

需要 macOS 的 Swift 工具鏈（Xcode 或 Command Line Tools）。

```sh
git clone --branch personal https://github.com/a2289866844/clipline.git
cd clipline
swift test
scripts/build-app.sh
open build/Clipline.app
```

`scripts/make-dmg.sh` 構建並輸出 DMG、ZIP 及 SHA-256 校驗檔。`personal` 是分享版分支；保留的 `main` 是上游基線，其他 `fix/*` 分支用於獨立上游 PR。

## 驗證與來源

回歸測試涵蓋顯示區域邊界、預覽時間、容量與還原、剪貼簿內容與儲存，以及點擊和拖曳資料格式。發布驗證需要另外檢查 arm64 / x86_64 通用 App、簽章與安裝包；自動測試不等同於所有顯示器、全螢幕 App 或實際拖放組合都已人工驗證。

## 操作示範與問題回報

**13 秒真實原生操作示範：截圖 → Clipline 浮層 → 拖到聊天輸入框。** 點擊預覽可觀看 MP4。

[![Clipline 原生截圖與拖放示範](docs/media/clipline-demo.gif)](https://github.com/a2289866844/clipline/releases/download/clipline-v1.1.0/Clipline-1.1.0-demo.mp4)

示範使用合成旅遊內容與本機聊天輸入框，實際接收原生拖放的圖片檔案，不會透過網路上傳或傳送。錄製的是與正式 App 相同原始碼、使用獨立儲存資料夾的驗證版；詳見 [示範說明](docs/demo.md)。

遇到問題可到 [GitHub Issues](https://github.com/a2289866844/clipline/issues) 回報，附上 macOS 與 Clipline 版本、重現步驟、預期與實際結果。分享截圖或錄影前請先移除私人內容。

保留上游的 MIT 原始碼授權與作者署名，見 [LICENSE](LICENSE)。原版名稱和圖示不包含在授權中，本版本的圖示由自己的腳本繪製。Swift target 和目錄名稱沿用 `Tendedero`，方便追蹤上游；發行的 App 名稱、Bundle ID、偏好設定和截圖儲存資料夾使用 Clipline。
