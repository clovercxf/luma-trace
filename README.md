# LumaTrace

**A local-first AI photo library for macOS.** Organize photos and videos by time, place, and projects; search recognized content; revisit memories; and review duplicate suggestions while keeping original files in place.

**LumaTrace is developed and published by Clover F.** This repository is publicly viewable, but the software and original assets are proprietary; no general reuse or open-source license is granted. GitHub's Terms still permit access and forking through the platform. See [LICENSE](LICENSE) for the full limits on reuse outside GitHub.

## English

### Features

- Index media from multiple folders you choose, with per-folder status and refresh controls.
- Browse by timeline and location; see map markers when GPS metadata is available.
- Search local labels, recognized text, and available descriptions.
- Analyze sampled or individual video frames.
- Review exact-duplicate and similar-media suggestions with reasons; nothing is deleted automatically.
- Create local memory films on demand or on a daily/weekly schedule.
- Preview media with trackpad zoom, swipe navigation, a filmstrip, and a closable information drawer.
- Choose English, Simplified Chinese, or Spanish.

### Privacy and permissions

Your index, thumbnails, and generated memories are stored on this Mac. LumaTrace has no account, analytics service, or LumaTrace cloud. The first launch presents the privacy policy for review and consent. macOS permissions are requested in context: selected folders when added, camera when motion capture is opened, and notifications when memory reminders are enabled. LumaTrace does not require Full Disk Access. Map tiles and place searches contact their providers; your photos are not sent with those requests. Optional Ollama connects only to `127.0.0.1:11434`.

Read [Privacy Policy](PRIVACY.md) and the [User Guide](USER_GUIDE.md) (also available in [简体中文](USER_GUIDE.zh-CN.md)).

### Build and test

Requirements: macOS 14+, Xcode Command Line Tools with Swift 5.9 or later.

```sh
./run-tests.command
./build-app.command
```

The build creates versioned files such as `LumaTrace-0.4.6-macOS-arm64.dmg` and a matching ZIP archive in this folder. The local app is ad hoc signed, not Developer ID signed or notarized, so Gatekeeper may show a warning. See [TESTING.md](TESTING.md) for test scope and known limits.

### Project documents

- [User Guide (English)](USER_GUIDE.md) · [用户手册（简体中文）](USER_GUIDE.zh-CN.md)
- [Changelog / 更新日志](CHANGELOG.md)
- [Release naming / 发布文件命名](RELEASE_NAMING.md)
- [Privacy Policy / 隐私政策](PRIVACY.md)
- [Security reporting](SECURITY.md)
- [Testing notes](TESTING.md)

---

## 简体中文

**面向 macOS 的本地优先 AI 相册。** 按时间、地点和任务整理照片与视频，搜索识别内容，回顾时光记忆，并查看重复影像建议；原始文件始终留在原位置。

**LumaTrace 由 Clover F 开发并发布。** 本仓库公开可见，但软件和原创素材为专有内容，不授予一般复用许可或开源许可。GitHub 服务条款仍允许在平台内访问和 fork。平台外的使用限制请阅读 [LICENSE](LICENSE)。

### 功能

- 为你选择的多个文件夹建立索引，并显示每个位置的状态与刷新操作。
- 按时间轴和地点浏览；有 GPS 元数据时在地图上显示标记。
- 搜索本地标签、识别文字和可用的画面描述。
- 对视频抽帧分析，也可选择逐帧深度分析。
- 查看完全重复和相似影像建议及原因；应用不会自动删除文件。
- 手动生成本地回忆短片，或按每天/每周的时间计划生成。
- 使用触控板缩放、滑动切换、缩略图胶片栏和可关闭的信息抽屉预览影像。
- 支持简体中文、English 和 Español。

### 隐私与权限

索引、缩略图和生成的回忆保存在这台 Mac 上。LumaTrace 不提供账号、分析追踪或自有云服务。首次启动会显示隐私政策，阅读并同意后才能继续。macOS 权限按功能在需要时请求：添加文件夹时访问所选位置，打开动态照片拍摄时申请相机权限，开启回忆提醒时申请通知权限。LumaTrace 无需“完全磁盘访问权限”。地图瓦片和地点搜索会连接相应服务，但不会随请求发送照片。可选 Ollama 仅连接本机 `127.0.0.1:11434`。

请阅读[隐私政策](PRIVACY.md)和[简体中文用户手册](USER_GUIDE.zh-CN.md)，也可查看[英文版手册](USER_GUIDE.md)。

### 构建与测试

需要 macOS 14 或更高版本，以及 Swift 5.9 或更新版本的 Xcode 命令行工具。

```sh
./run-tests.command
./build-app.command
```

构建会在本目录生成带版本号和架构的文件，例如 `LumaTrace-0.4.6-macOS-arm64.dmg` 及对应 ZIP。本地应用使用临时签名，尚未使用 Developer ID 签名或公证，因此 Gatekeeper 可能显示安全提示。测试范围和已知限制见 [TESTING.md](TESTING.md)。

### 项目文档

- [用户手册（简体中文）](USER_GUIDE.zh-CN.md) · [User Guide (English)](USER_GUIDE.md)
- [更新日志 / Changelog](CHANGELOG.md)
- [隐私政策 / Privacy Policy](PRIVACY.md)
- [安全问题反馈](SECURITY.md)
- [测试说明](TESTING.md)
