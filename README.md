# LumaTrace

**A private, local-first AI photo library for macOS.** Organize photos and videos by time, place, and projects; search recognized content; revisit memories; and review duplicate suggestions without moving your originals.

LumaTrace is published by Clover F. It is built with Swift and SwiftUI for macOS 14 or later. The interface is available in English, 简体中文, and Español.

## What it does

- Indexes media from multiple folders you choose, with per-folder status and refresh controls.
- Groups media on a timeline and by location, with map markers when GPS metadata is available.
- Searches local labels, recognized text, and available descriptions.
- Extracts video frames for analysis, with an optional deeper frame-by-frame mode.
- Shows duplicate and similar-media suggestions with a reason to help you decide what to keep.
- Creates local memory films on demand or on a daily/weekly schedule.
- Opens a native-style preview with trackpad zoom, swipe navigation, a filmstrip, and an information drawer.

## Privacy by design

Media originals stay in their existing folders. The library index, thumbnails, preferences, and generated memory films are stored on this Mac. LumaTrace does not upload your media to a LumaTrace server and contains no account, advertising, or analytics service.

The optional map loads OpenStreetMap tiles. The map provider receives ordinary tile requests, your network address, and the approximate map area being viewed; photo files and embedded GPS coordinates are not sent. Optional Ollama descriptions connect only to `127.0.0.1:11434`. See [PRIVACY.md](PRIVACY.md) for details.

## Build from source

Requirements: macOS 14+, Xcode Command Line Tools with Swift 5.9 or later, and a Mac capable of running SwiftUI.

```sh
./build-app.command
```

This creates `LumaTrace-macOS.zip` in the repository root. The local build is ad hoc signed; it is not Developer ID signed or notarized, so Gatekeeper may show a warning. See [USER_GUIDE.md](USER_GUIDE.md) for setup and use.

## Tests

```sh
./run-tests.command
```

Some Vision and AVFoundation cases depend on the macOS version and installed Swift Testing plugin. See [TESTING.md](TESTING.md) for the latest verification notes and known limits.

## Project documents

- [User guide](USER_GUIDE.md) · [Guía de usuario](USER_GUIDE.es.md) · [用户手册](USER_GUIDE.zh-CN.md)
- [Privacy policy](PRIVACY.md)
- [Security reporting](SECURITY.md)
- [Testing notes](TESTING.md)
- [Brand assets](BrandAssets/BRAND_ASSETS.md)

## License

Copyright © 2026 Clover F. All rights reserved. No open-source license has been granted. Public visibility does not grant permission to reuse, redistribute, or publish modified versions of this source.
