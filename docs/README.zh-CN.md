# wardrobe

**简体中文** · [繁體中文](README.zh-TW.md) · [English](../README.md) · [Français](README.fr.md) · [Deutsch](README.de.md) · [日本語](README.ja.md) · [Русский](README.ru.md)

<img src="clipline-icon.png" alt="wardrobe 图标" width="80">

macOS 截屏与剪贴板卡片架：收集文字、链接、图片和文件，复制完整内容或拖到其他 App。

由 **[@a2289866844](https://github.com/a2289866844)** 开发，原名 Clipline。

## 功能

**1.2 预览版**加入历史记录、中文与截图 OCR 搜索、置顶和文字编辑。每页六张卡片，可浏览最近 120 张，更早的记录仍可从数据库搜索。

**Control + Option + T** 显示或隐藏卡片架；**Command + Shift + V** 在 1.2 打开搜索。也可将指针移到刘海附近或屏幕顶部中央显示卡片。

## 获取版本

| 版本 | 要求 | 下载 |
| --- | --- | --- |
| 1.1.6 稳定版，使用旧名 Clipline | macOS 14+ | [DMG / ZIP](https://github.com/a2289866844/Your-mums-wardrobe/releases/tag/clipline-v1.1.6) |
| 1.2 开发预览，含历史、搜索与 OCR | macOS 15+、Swift 6 | [从源码构建](https://github.com/a2289866844/Your-mums-wardrobe/tree/codex/clipline-public-1.2)，尚无公开安装包 |

稳定版安装程序仍是 `Clipline.app`，不含数据库历史功能。它使用 ad-hoc 签名，未经 Apple 公证。[稳定版安装说明](https://github.com/a2289866844/Your-mums-wardrobe/blob/976a4ad/README.md) · [旧版 1.1 截屏与拖放演示](https://github.com/a2289866844/Your-mums-wardrobe/releases/download/clipline-v1.1.3/Clipline-1.1.3-demo.mp4)

<details>
<summary>构建 1.2 预览版</summary>

```sh
git clone --branch codex/clipline-public-1.2 https://github.com/a2289866844/Your-mums-wardrobe.git
cd Your-mums-wardrobe
swift test
scripts/build-app.sh
open build/wardrobe.app
```

</details>

历史以 **未加密 SQLite** 保存在 Mac 上。复制敏感内容前，请先关闭 **Hang copied items**。已有的加密 Clipd 数据库须备份并使用原始密钥，另行离线转换。[存储与兼容性详情](https://github.com/a2289866844/Your-mums-wardrobe/blob/codex/clipline-public-1.2/docs/reviews/clipline-clipd-integration.md)

基于 **Alejandro Buján 的 [Tendedero](https://github.com/alejandrobujan/tendedero)**，为独立修改版。[贡献与致谢](https://github.com/a2289866844/Your-mums-wardrobe/blob/codex/clipline-public-1.2/AUTHORS.md) · [许可证](https://github.com/a2289866844/Your-mums-wardrobe/blob/codex/clipline-public-1.2/LICENSE) · [反馈问题](https://github.com/a2289866844/Your-mums-wardrobe/issues)
