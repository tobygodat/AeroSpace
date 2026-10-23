#!/bin/sh
# Runs the keybinding editor tests with the Command Line Tools only (no Xcode needed).
# The upstream XCTest suite is skipped; it needs Xcode.
cd "$(dirname "$0")"
fw=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
lib=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
plugins=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
AEROSPACE_SKIP_XCTEST=1 swift test --filter KeybindingEditorTests \
    -Xswiftc -F -Xswiftc "$fw" -Xswiftc -plugin-path -Xswiftc "$plugins" -Xlinker -F -Xlinker "$fw" \
    -Xlinker -rpath -Xlinker "$fw" -Xlinker -rpath -Xlinker "$lib" "$@"
