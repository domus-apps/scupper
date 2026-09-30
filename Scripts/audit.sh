#!/bin/bash
# Scans every installed app, read-only, and shows how what Scupper would
# offer differs from the last accepted snapshot: run it after changing a
# matching rule, read the diff, accept it once every line is right. The
# snapshots list this Mac's own files, so they stay in audit/ (ignored by
# git) and never go into the repo.
#   Scripts/audit.sh           scan and show what changed
#   Scripts/audit.sh --accept  make the latest scan the baseline
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p audit

if [[ "${1:-}" == "--accept" ]]; then
    cp audit/current.txt audit/baseline.txt
    echo "Baseline updated: $(grep -c '^  \[' audit/baseline.txt) items."
    exit 0
fi

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

if ! SCUPPER_AUDIT="$PWD/audit/current.txt" swift test ${PLUGIN_FLAGS[@]+"${PLUGIN_FLAGS[@]}"} \
    --filter auditSnapshot > audit/test.log 2>&1; then
    tail -20 audit/test.log
    exit 1
fi

if [[ ! -f audit/baseline.txt ]]; then
    cp audit/current.txt audit/baseline.txt
    echo "First snapshot saved as the baseline: $(grep -c '^  \[' audit/baseline.txt) items."
    exit 0
fi

if diff -u audit/baseline.txt audit/current.txt; then
    echo "No changes."
fi
