#!/bin/bash
# Runs the unit tests. Kept as the stable entry point even though it is
# mostly a passthrough — with full Xcode installed, plain `swift test`
# needs no extra flags. (Command Line Tools alone can't run Swift Testing.)
set -euo pipefail
cd "$(dirname "$0")/.."

# Some toolchains stage Sparkle.framework next to the app binary but not in
# PackageFrameworks, which is where the test bundle's rpath points — mirror
# it so the bundle can load.
# With only the Command Line Tools installed, SwiftPM doesn't hand the
# compiler the Swift Testing macro plugin (it sits one folder down, in
# plugins/testing), so @Test fails to expand ("plugin for module
# 'TestingMacros' not found") — unless the build happens to reuse an
# earlier one. Point the compiler at it. Xcode's toolchain needs nothing.
TESTING_PLUGINS="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
PLUGIN_FLAGS=()
if [[ -d "$TESTING_PLUGINS" ]]; then
    PLUGIN_FLAGS=(-Xswiftc -plugin-path -Xswiftc "$TESTING_PLUGINS")
fi

swift build --build-tests ${PLUGIN_FLAGS[@]+"${PLUGIN_FLAGS[@]}"}
STAGED=.build/out/Products/Debug/Sparkle.framework
DEST=.build/out/Products/Debug/PackageFrameworks
if [[ -d "$STAGED" && ! -d "$DEST/Sparkle.framework" ]]; then
    mkdir -p "$DEST"
    cp -R "$STAGED" "$DEST/"
fi

swift test ${PLUGIN_FLAGS[@]+"${PLUGIN_FLAGS[@]}"} "$@"
