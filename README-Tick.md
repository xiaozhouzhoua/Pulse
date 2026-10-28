# Tick

基于 Pulse v0.15.8 的本地 macOS / iOS 行情应用。

- 上游：https://github.com/fatwang2/Pulse（remote `upstream`，仅拉取，推送地址已禁用）
- Fork：https://github.com/xiaozhouzhoua/Pulse（remote `origin`，`quote` 分支推送至此；不向上游发起任何合并请求）
- 基础提交：86cbf2526b1d25f18d5342e35e55f8ca1c3d884e
- 许可证：MIT，原始 LICENSE 和版权声明保留。
- 应用名称：Tick（2026-10-23 起由 Quote 改名，本地工程名 2026-10-25 同步改为 Tick）
- App Store 名称：Tick 行情（App ID `6827031222`，SKU `tick-universal`）
- 应用标识：`com.DD495M342Y.tick`（双端共用，一次购买通用）；开发版 `local.quote.mac.dev` / `local.quote.ios.dev`
- 内部 PulseCore / PulseUI 模块名称保留。
- 自选、设置和钥匙串凭据使用独立应用标识。
- 未配置上游自动更新或 TelemetryDeck 分析 ID。

## Target

| Target | 平台 | 用途 |
|---|---|---|
| `PulseMac` | macOS | 直发版（DMG/zip，可配 Sparkle） |
| `TickAppStore` | macOS | Mac App Store 版，无 Sparkle |
| `TickiOS` | iOS 26+ | App Store 版，Longbridge 以静态库链接 |

## 构建

需要 Xcode 26+、XcodeGen、Rust（`aarch64-apple-darwin`、`aarch64-apple-ios`、`aarch64-apple-ios-sim`）。

```sh
xcodegen generate

# macOS 直发
xcodebuild -project Tick.xcodeproj -scheme PulseMac -configuration Release -derivedDataPath build build CODE_SIGN_IDENTITY=-

# macOS App Store（需签名证书与描述文件）
xcodebuild -project Tick.xcodeproj -scheme TickAppStore -configuration Release \
  -destination 'generic/platform=macOS' -archivePath build/archives/Tick.xcarchive archive

# iOS App Store
xcodebuild -project Tick.xcodeproj -scheme TickiOS -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/archives/Tick-iOS.xcarchive archive
```

产物：`build/Build/Products/Release/Tick.app`（本地直发，ad-hoc 签名）。

## 上架

`metadata/` 存放 macOS 四语言商店文案，`metadata-ios/` 存放 iOS 专属文案（去掉菜单栏、持仓、分享卡与本地 MCP 等 Mac 功能），`.asc/workflow.json` 提供归档/上传/挂载/校验流程：

```sh
asc workflow validate
asc workflow run --dry-run mac-stage
asc workflow run mac-release SUBMIT_FOR_REVIEW:true
asc workflow run ios-release SUBMIT_FOR_REVIEW:true
```

两个平台共用同一个 App 记录和 App 信息（名称、副标题），所以副标题使用跨平台表述；版本描述按平台分别维护。

商店页：隐私政策 <https://xiaozhouzhoua.github.io/tick/privacy.html>，支持页 <https://xiaozhouzhoua.github.io/tick/support.html>。

历史源码中的网站和发布脚本保留作来源参考。

