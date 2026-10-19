#!/bin/zsh
set -eu
cd "${0:A:h}"
BUILD_ROOT="${TMPDIR:-/tmp}/LumaTrace-build-${UID}"
mkdir -p "$BUILD_ROOT"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_ROOT/swift"
swift build -c release -debug-info-format none --scratch-path "$BUILD_ROOT/build" --cache-path "$BUILD_ROOT/package" --manifest-cache local --disable-sandbox
BIN_DIR=$(swift build -c release -debug-info-format none --scratch-path "$BUILD_ROOT/build" --cache-path "$BUILD_ROOT/package" --manifest-cache local --disable-sandbox --show-bin-path)
APP_ROOT=$(mktemp -d "$BUILD_ROOT/package.XXXXXX")
APP="$APP_ROOT/LumaTrace.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/LumaTrace" "$APP/Contents/MacOS/LumaTrace"
cp "$PWD/Info.plist" "$APP/Contents/Info.plist"
ditto --norsrc --noextattr "$PWD/BrandAssets" "$APP/Contents/Resources"
cp "$PWD/PRIVACY.md" "$APP/Contents/Resources/PrivacyPolicy.md"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PWD/Info.plist")
ARCHS=$(lipo -archs "$BIN_DIR/LumaTrace" | tr ' ' '-')
DMG="$PWD/LumaTrace-${VERSION}-macOS-${ARCHS}.dmg"
ZIP="$PWD/LumaTrace-${VERSION}-macOS-${ARCHS}.zip"
rm -f "$DMG" "$ZIP"
STAGE="$APP_ROOT/dmg-root"
mkdir -p "$STAGE"
ditto --norsrc --noextattr "$APP" "$STAGE/LumaTrace.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "LumaTrace" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
ditto -c -k --norsrc --keepParent "$APP" "$ZIP"
echo "安装包已生成：$DMG"
open -R "$DMG"
