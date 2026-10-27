#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
mkdir -p .build/cooling
# IOKit calls and geteuid are replaced in this test; it never writes real fan settings.
xcrun clang Tests/CSMCTests/test_smc.c -I Sources/CSMC/include -framework IOKit -o .build/cooling/test-smc
.build/cooling/test-smc
