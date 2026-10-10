# Clipline

<img src="docs/clipline-icon.png" alt="Clipline 圖示" width="96">

我的 macOS 截圖浮層定制版，基於 [Alejandro Buján 的 Tendedero](https://github.com/alejandrobujan/tendedero) 1.0.0。Clipline 是獨立改版，使用自己的名稱和圖示。

**[下載安裝包](https://github.com/a2289866844/clipline/releases/latest)** · macOS 14 或更新版本 · Apple Silicon / Intel 通用版

## 安裝與使用

1. 在 Releases 下載 `Clipline-1.0.1-universal.dmg`。
2. 打開磁碟映像，把 `Clipline.app` 拖到 `Applications`，再啟動。
3. 如果 macOS 阻擋開啟，到「系統設定 → 隱私權與安全性」，找到 Clipline 的提示並按「強制打開 / Open Anyway」。這個分享版採用 ad-hoc 簽章，未經 Apple 公證；[Apple 開啟說明](https://support.apple.com/guide/mac-help/mh40616/mac)。
4. 依 macOS 提示允許存取截圖所在資料夾。頂端選單列的迴紋針是 Clipline。

按 **Control + Option + T** 顯示或隱藏截圖列。點擊圖片可複製，拖到其他 App 可分享；拖到資料夾會保留檔案並從截圖列移除。初次啟動會詢問是否接管截圖儲存位置，你可以選擇「Not now」。

啟用 **Handle screenshots** 會把新截圖存到 `~/Library/Application Support/Clipline/Screenshots`，並關閉 macOS 浮動縮圖；關閉該選項或正常退出時恢復先前設定。接管模式下，圖片右上角的叉會將其檔案送到垃圾桶。請避免和其他會接管截圖設定的工具同時啟用這項功能。

## 這個版本的操作規則

- 熱區停留約 **0.08 秒**即可召喚，彈出動畫更快，熱區也稍微放寬。
- 滑鼠召喚後，在該螢幕的**整個頂部三分之一**範圍內保持顯示；離開便收起。
- **新截圖顯示 3 秒**，下一張新截圖重新計時；滑鼠停在熱區時，收起後需要先移開才能再次召喚。
- 快捷鍵或選單手動召喚會保持開啟，滑鼠進入浮層再離開後，等待 **5 秒**收起。
- 切換 App 或桌面不重置收起倒數，支援全螢幕 Space。
- 圖片卡片加大，並修正頂部邊界反覆彈出與收起的問題。
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

本版本提供 16 項回歸測試，涵蓋顯示區域邊界、3 秒預覽、容量及還原、圖片讀取失敗與後續寫入。發布前執行測試，構建 arm64 / x86_64 通用 App，並驗證簽章與安裝包。這些自動測試不等同於每種顯示器、全螢幕 App 及滑鼠操作組合都已人工驗證。

保留上游的 MIT 原始碼授權與作者署名，見 [LICENSE](LICENSE)。原版名稱和圖示不包含在授權中，本版本的圖示由自己的腳本繪製。Swift target 和目錄名稱沿用 `Tendedero`，方便追蹤上游；發行的 App 名稱、Bundle ID、偏好設定和截圖儲存資料夾使用 Clipline。
