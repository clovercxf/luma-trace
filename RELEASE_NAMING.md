# Release artifact naming / 发布文件命名规范

Use the same stable pattern for every platform:

`LumaTrace-<version>-<platform>-<architecture>[-<artifact>].<extension>`

Examples:

- `LumaTrace-1.1R-macOS-arm64.dmg`
- `LumaTrace-1.1R-macOS-x86_64.dmg`
- `LumaTrace-1.1R-Windows-x64-Setup.exe`
- `LumaTrace-1.1R-Windows-arm64-Setup.exe`
- `LumaTrace-1.1R-Windows-x64-Portable.zip`

Use `Universal` only when a macOS binary actually contains both `arm64` and `x86_64` slices. Keep the product spelling `LumaTrace` exact; use hyphens, no spaces, and match the embedded app version. Add `-Setup` only to an installer and `-Portable` only to a portable archive. Do not upload a Windows-named artifact until a Windows build exists and passes its own validation.

每个平台使用统一格式：

`LumaTrace-<版本>-<平台>-<架构>[-<制品类型>].<扩展名>`

示例：

- `LumaTrace-1.1R-macOS-arm64.dmg`
- `LumaTrace-1.1R-macOS-x86_64.dmg`
- `LumaTrace-1.1R-Windows-x64-Setup.exe`
- `LumaTrace-1.1R-Windows-arm64-Setup.exe`
- `LumaTrace-1.1R-Windows-x64-Portable.zip`

只有 macOS 二进制确实同时包含 `arm64` 和 `x86_64` 时才能标为 `Universal`。产品名始终写作 `LumaTrace`，使用连字符且不加空格，并确保与应用内版本一致。仅安装程序使用 `-Setup`，仅便携压缩包使用 `-Portable`。Windows 版本完成移植并通过独立验证前，不得上传带 Windows 名称的制品。

## Current platform support / 当前平台支持

The current application is a native macOS app built on SwiftUI, AppKit, AVFoundation, and MapKit, and its package manifest targets macOS 14+. These Apple frameworks do not produce a Windows application. A real Windows release requires a Windows UI and replacements for media analysis, map, file permission, and packaging integrations; its installer must be built and tested on Windows before using the names above.

当前应用是 macOS 原生程序，使用 SwiftUI、AppKit、AVFoundation 和 MapKit，且 Swift Package 明确指定 macOS 14+。这些 Apple 框架不能产出 Windows 应用。真正的 Windows 版本需要实现 Windows 界面，并替换媒体分析、地图、文件授权和打包集成；必须在 Windows 上构建并测试安装程序后，才能采用上述命名。
