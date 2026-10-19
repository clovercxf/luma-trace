#!/bin/zsh
set -eu
cd "${0:A:h}"
TEST_ROOT="${TMPDIR:-/tmp}/lumatrace-tests-${UID}"
mkdir -p "$TEST_ROOT"
export LUMATRACE_LIBRARY="$TEST_ROOT/library"
export CLANG_MODULE_CACHE_PATH="$PWD/.build-cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build-cache/swift"
TEST_PLUGIN="$(xcode-select -p)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
# Each suite owns the same isolated writer; run them in separate processes.
RESULT=0
for TEST_SUITE in LibraryTests WorkflowAuditTests; do
    if [[ -f "$TEST_PLUGIN" ]]; then
        if swift test --disable-xctest --enable-swift-testing --filter "$TEST_SUITE" --scratch-path "$TEST_ROOT/build" --cache-path .build-cache/package --manifest-cache local --disable-sandbox -Xswiftc -load-plugin-library -Xswiftc "$TEST_PLUGIN"; then :; else RESULT=1; fi
    else
        if swift test --disable-xctest --enable-swift-testing --filter "$TEST_SUITE" --scratch-path "$TEST_ROOT/build" --cache-path .build-cache/package --manifest-cache local --disable-sandbox; then :; else RESULT=1; fi
    fi
done
exit "$RESULT"
