# Tick

基于 Pulse v0.15.8 的本地 macOS 复刻版本。

- 上游：https://github.com/fatwang2/Pulse
- 基础提交：86cbf2526b1d25f18d5342e35e55f8ca1c3d884e
- 许可证：MIT，原始 LICENSE 和版权声明保留。
- 应用名称：Tick（2026-10-23 起由 Quote 改名，本地工程名 2026-10-25 同步改为 Tick）
- 应用标识：local.quote.mac（开发版 local.quote.mac.dev）
- 内部 PulseCore / PulseUI 模块名称保留。
- 自选、设置和钥匙串凭据使用独立应用标识。
- 未配置上游自动更新或 TelemetryDeck 分析 ID。

## 构建

需要 Xcode 26+、XcodeGen、Rust（aarch64-apple-darwin target）。

```sh
xcodegen generate
xcodebuild -project Tick.xcodeproj -scheme PulseMac -configuration Release -derivedDataPath build build CODE_SIGN_IDENTITY=-
```

产物：`build/Build/Products/Release/Tick.app`。本地构建使用 ad-hoc 签名。

历史源码中的网站和发布脚本保留作来源参考；本地构建不执行发布操作。
