# macOS 預覽程式圖片視窗置中

日期：2026-10-11。依使用者選擇，保留 macOS「預覽程式」，只調整圖片視窗位置。

## 行為

- 點擊圖片卡片，以 Preview 開啟，置中於點擊當下游標所在螢幕的可用區域；不改視窗大小。
- 以 Accessibility 的完整文件路徑識別圖片，支援 Unicode、file URL、一般路徑與連結解析。同名但不同路徑的視窗不會移動；缺少文件身分時停止置中。
- 等待 Preview 視窗尺寸穩定後移動，讀回位置與大小才回報成功。最多重試 2.5 秒；後一次點擊取消前一次待處理請求。
- 未取得輔助使用權限仍正常開啟圖片。正式 app 首次需要時請求權限；授權後需再次點擊圖片。隔離驗證 app 不彈權限提示。

## 已驗證

- 完整測試 **130/130 通過**，零失敗，47.5 秒；含六個新增測試，涵蓋可用區域、左側與上方螢幕座標、無效幾何、同名文件、缺失身分及重複文件視窗。
- arm64 與 x86_64 release 建置通過，Universal 架構正確，`codesign --verify --deep --strict` 通過。編譯無 warning/error。
- 隔離原生驗證 app 的圖片卡片實際開啟 Preview；Accessibility tree 的文件 URL 與點擊的 `Clipline-center-check-10.png` 一致。
- 該驗證 app 回報 `needsAccessibility`，沒有修改權限。因此**尚未完成實際移動／置中的端到端驗證**。
- 已安裝的 Clipline 尚未替換。待使用者確認套用修正版與啟用輔助使用權限後，再驗證實際視窗位置。

原生日誌與建置／測試日誌保存在 `build/centering-evidence`。開啟證據：

![原生 Preview 開啟驗證圖片，尚未授權置中](evidence/preview-open-before-access.png)
