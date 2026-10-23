#!/bin/sh
# Runs the workspace layout tests with the Command Line Tools only (no Xcode needed).
# The upstream XCTest suite is skipped; it needs Xcode.
cd "$(dirname "$0")"
fw=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
lib=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
AEROSPACE_SKIP_XCTEST=1 swift test --filter WorkspaceLayoutTests \
    -Xswiftc -F -Xswiftc "$fw" -Xlinker -F -Xlinker "$fw" \
    -Xlinker -rpath -Xlinker "$fw" -Xlinker -rpath -Xlinker "$lib" "$@"
