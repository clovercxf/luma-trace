#!/bin/zsh
set -u
cd "${0:A:h}"
OUT="$PWD/QA_REPORT.md"
LOG_ROOT="${TMPDIR:-/tmp}/LumaTrace-QA-${UID}"
mkdir -p "$LOG_ROOT"
TEST_LOG="$LOG_ROOT/tests.log"
BUILD_LOG="$LOG_ROOT/build.log"
DOCS=PASS
TESTS=FAIL
BUILD=FAIL
DMG=FAIL

for required in README.md USER_GUIDE.md USER_GUIDE.zh-CN.md CHANGELOG.md LICENSE PRIVACY.md RELEASE_NAMING.md; do
  if [[ ! -s "$required" ]]; then DOCS=FAIL; fi
done
if ! rg -q '## English' README.md || ! rg -q '## 简体中文' README.md || ! rg -q 'Copyright.*Clover F' LICENSE || ! rg -q '事先书面许可' LICENSE; then DOCS=FAIL; fi
if [[ "$DOCS" == PASS ]]; then echo "Documentation and rights checks: PASS"; fi

if ./run-tests.command >"$TEST_LOG" 2>&1; then TESTS=PASS; else TESTS=FAIL; fi
if ./build-app.command >"$BUILD_LOG" 2>&1; then BUILD=PASS; else BUILD=FAIL; fi
DMG_FILE=$(find "$PWD" -maxdepth 1 -name 'LumaTrace-*-macOS-*.dmg' -print -quit)
if [[ -n "$DMG_FILE" && -s "$DMG_FILE" ]]; then
  MOUNT="$LOG_ROOT/mount"
  mkdir -p "$MOUNT"
  if hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT" "$DMG_FILE" >>"$BUILD_LOG" 2>&1; then
    if [[ -d "$MOUNT/LumaTrace.app" && -f "$MOUNT/LumaTrace.app/Contents/Resources/PrivacyPolicy.md" && -L "$MOUNT/Applications" ]] && /usr/bin/codesign --verify --deep --strict "$MOUNT/LumaTrace.app" >>"$BUILD_LOG" 2>&1; then DMG=PASS; fi
    hdiutil detach "$MOUNT" >>"$BUILD_LOG" 2>&1 || true
  fi
fi

TEST_SUMMARY=$(rg 'Test run with .* in .* suite' "$TEST_LOG" | sed 's/^↳ //' | tr '\n' '; ')
TEST_FAILURES=$(awk '/^✘ Test .* failed after/ {n++} END {print n+0}' "$TEST_LOG")
TEST_DETAILS=$(rg '^✘ Test .* (recorded an issue|failed after)' "$TEST_LOG" | sed 's/^[^:]*: //' | tr '\n' '; ')
BUILD_NOTES=$(rg -m 3 'warning:|error:' "$BUILD_LOG" | sed 's/^[[:space:]]*//' | tr '\n' '; ')
DATE=$(date '+%Y-%m-%d %H:%M %Z')
cat > "$OUT" <<EOF
# LumaTrace Release QA Report / 发布前测试报告

- Run time / 测试时间: $DATE
- App version / 应用版本: 0.4.6 (18)
- Host / 测试环境: $(sw_vers -productName) $(sw_vers -productVersion), $(uname -m)

## Results / 结果

| Area / 项目 | Result / 结果 |
|---|---|
| Documentation, bilingual content, and Clover F proprietary notice / 双语文档与版权限制 | $DOCS |
| Automated Swift tests / Swift 自动化测试 | $TESTS ($TEST_FAILURES test or suite failure records) |
| Release app build / Release 应用构建 | $BUILD |
| DMG mount, app bundle, and code-signature integrity / DMG 挂载、应用包与签名完整性 | $DMG |
| Windows package / Windows 安装包 | NOT BUILT — current target is macOS-only / 未构建：当前项目仅支持 macOS |

Test suite summaries / 测试套件摘要: $TEST_SUMMARY

Test failures / 测试失败详情: ${TEST_DETAILS:-None / 无}

Build diagnostics / 构建诊断: ${BUILD_NOTES:-None / 无}

## Coverage / 覆盖范围

Automated suites exercise folder navigation and multi-root scanning, pause/resume/stop, incremental previews and search, duplicate recommendations, metadata and location handling, retry/read-only/corrupt-library workflows, multilingual search, scheduled memories, video sampling modes, camera lifecycle safety, local-model validation, and map coordinate clustering.

自动化套件覆盖文件夹导航与多目录扫描、暂停/继续/停止、增量预览与搜索、重复影像建议、元数据和位置、重试/只读/损坏资料库、多语言搜索、定时回忆、视频抽帧模式、相机生命周期、本机模型校验及地图坐标聚合。

Platform limitation / 平台限制: the current SwiftUI/AppKit/AVFoundation/MapKit app targets macOS 14 and cannot produce a Windows installer. A separate Windows implementation is required; no invalid Windows artifact was generated.

当前 SwiftUI/AppKit/AVFoundation/MapKit 应用以 macOS 14 为目标，不能直接生成 Windows 安装包。需要单独实现 Windows 版本，因此没有生成不可用的 Windows 制品。

Manual follow-up still required / 仍需人工验证: first-launch consent and language switching, native macOS folder authorization, camera and notification prompts, trackpad gestures, and the final install flow. These depend on interactive macOS UI and real hardware and are not claimed as automated pass results.

首次隐私同意与语言切换、macOS 文件夹授权窗口、相机和通知系统弹窗、触控板手势及最终安装流程仍需人工交互验证；这些依赖真实 macOS 界面和硬件，本报告不将其标为自动化通过。

EOF

if [[ "$DOCS" == PASS && "$TESTS" == PASS && "$BUILD" == PASS && "$DMG" == PASS ]]; then
  echo "Overall: macOS package validation PASS; Windows port is a separate implementation task." >> "$OUT"
else
  echo "Overall: NEEDS REVIEW — see test and build diagnostics above; environment-dependent media tests may require a fully provisioned macOS host." >> "$OUT"
fi
echo "QA report: $OUT"
echo "Status: docs=$DOCS tests=$TESTS build=$BUILD dmg=$DMG"
[[ "$DOCS" == PASS && "$TESTS" == PASS && "$BUILD" == PASS && "$DMG" == PASS ]]
