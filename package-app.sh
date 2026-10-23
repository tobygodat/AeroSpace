#!/bin/sh
# Packages the fork as "AeroSpace Omarchy.app" from the SwiftPM release build. No Xcode needed.
#
#   ./package-app.sh             build into .release/
#   ./package-app.sh --install   also install into ~/Applications
#
# Signing is ad-hoc by default. macOS ties the Accessibility permission of an ad-hoc signed app to the exact
# build, so after every rebuild you need to re-enable it in System Settings → Privacy & Security → Accessibility.
# Set CODESIGN_IDENTITY to a self-signed code signing certificate to keep the permission across rebuilds.
set -e
cd "$(dirname "$0")"

app_name="AeroSpace Omarchy"
bundle_id="dev.tobygodat.aerospace-omarchy"
identity="${CODESIGN_IDENTITY:--}"
version="$(git describe --tags --abbrev=0 | sed 's/^v//')-omarchy"
build_number="$(git rev-list --count HEAD)"

swift build -c release --product AeroSpaceApp
bin_path="$(swift build -c release --product AeroSpaceApp --show-bin-path)"

app=".release/$app_name.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_path/AeroSpaceApp" "$app/Contents/MacOS/AeroSpace"
cp docs/config-examples/default-config.toml "$app/Contents/Resources/"

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>AeroSpace</string>
    <key>CFBundleIdentifier</key><string>$bundle_id</string>
    <key>CFBundleName</key><string>$app_name</string>
    <key>CFBundleDisplayName</key><string>$app_name</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$build_number</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

codesign --force --sign "$identity" --entitlements resources/AeroSpace.entitlements "$app"
codesign --verify --strict "$app"
echo "Built $app ($version, build $build_number)"

if [ "$1" = "--install" ]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/$app_name.app"
    ditto "$app" "$HOME/Applications/$app_name.app"
    echo "Installed to ~/Applications/$app_name.app"
fi
