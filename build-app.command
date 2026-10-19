#!/bin/zsh
set -eu
cd "${0:A:h}"
BUILD_ROOT="${TMPDIR:-/tmp}/LumaTrace-build-${UID}"
mkdir -p "$BUILD_ROOT"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_ROOT/swift"
swift build -c release --scratch-path "$BUILD_ROOT/build" --cache-path "$BUILD_ROOT/package" --manifest-cache local --disable-sandbox
BIN_DIR=$(swift build -c release --scratch-path "$BUILD_ROOT/build" --cache-path "$BUILD_ROOT/package" --manifest-cache local --disable-sandbox --show-bin-path)
APP_ROOT=$(mktemp -d "$BUILD_ROOT/package.XXXXXX")
APP="$APP_ROOT/LumaTrace.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/LumaTrace" "$APP/Contents/MacOS/LumaTrace"
cp "$PWD/Info.plist" "$APP/Contents/Info.plist"
ditto --norsrc --noextattr "$PWD/BrandAssets" "$APP/Contents/Resources"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --norsrc --keepParent "$APP" "$PWD/LumaTrace-macOS.zip"
echo "应用已生成：$PWD/LumaTrace-macOS.zip"
open -R "$PWD/LumaTrace-macOS.zip"
