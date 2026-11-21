#!/bin/sh
# Builds build.noindex/MicLock.app: a universal (arm64 + x86_64) binary, Info.plist, icon,
# ad-hoc signature. Used by install.sh locally and by the release workflow in CI.
#   VERSION=1.2.0 ./build.sh   (default: the latest git tag without "v", else 0.0.0)
set -eu
cd "$(dirname "$0")"
LABEL=org.anybyte.miclock
MIN_MACOS=13.0
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0}"
# Must grow on every build: Control Center caches a control's rendering per bundle version.
BUILD="${BUILD:-$(date +%Y%m%d%H%M)}"
APP=build.noindex/MicLock.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build.noindex/obj
for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target "$arch-apple-macos$MIN_MACOS" -o "build.noindex/obj/MicLock-$arch" main.swift
done
lipo -create -output "$APP/Contents/MacOS/MicLock" build.noindex/obj/MicLock-arm64 build.noindex/obj/MicLock-x86_64

# Control Center toggle: a WidgetKit extension, macOS 26+ (needs the macOS 26 SDK to build).
EXT="$APP/Contents/PlugIns/MicLockWidget.appex"
mkdir -p "$EXT/Contents/MacOS"
OBJ="$PWD/build.noindex/obj"
for arch in arm64 x86_64; do
    swiftc -O -wmo -swift-version 5 -parse-as-library -application-extension -module-name MicLockWidget \
        -target "$arch-apple-macos26.0" -Xlinker -e -Xlinker _NSExtensionMain \
        -Xfrontend -const-gather-protocols-file -Xfrontend "$PWD/widget/const-protocols.json" \
        -emit-const-values-path "$OBJ/Widget-$arch.swiftconstvalues" \
        -o "$OBJ/MicLockWidget-$arch" widget/Widget.swift
done
lipo -create -output "$EXT/Contents/MacOS/MicLockWidget" "$OBJ/MicLockWidget-arm64" "$OBJ/MicLockWidget-x86_64"
# Metadata.appintents: without it the system can't run the toggle's intent. Xcode normally
# generates it; this is the same tool fed with the compiler's const values.
echo "$PWD/widget/Widget.swift" > "$OBJ/widget-sources.txt"
echo "$OBJ/Widget-arm64.swiftconstvalues" > "$OBJ/widget-consts.txt"
mkdir -p "$EXT/Contents/Resources"
xcrun appintentsmetadataprocessor --output "$EXT/Contents/Resources" \
    --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" --module-name MicLockWidget \
    --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" --xcode-version "$(xcodebuild -version | awk '/Build version/{print $3}')" \
    --platform-family macOS --deployment-target 26.0 --target-triple arm64-apple-macos26.0 \
    --source-file-list "$OBJ/widget-sources.txt" --swift-const-vals-list "$OBJ/widget-consts.txt" \
    --binary-file "$OBJ/MicLockWidget-arm64" --no-app-shortcuts-localization --deployment-aware-processing >/dev/null 2>&1
test -f "$EXT/Contents/Resources/Metadata.appintents/extract.actionsdata"
# Custom "mic + padlock" symbols for the control (widget/Assets.xcassets).
xcrun actool widget/Assets.xcassets --compile "$EXT/Contents/Resources" --platform macosx \
    --target-device mac --minimum-deployment-target 26.0 \
    --output-partial-info-plist "$OBJ/widget-assets.plist" >/dev/null
cat > "$EXT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$LABEL.widget</string>
  <key>CFBundleName</key><string>MicLockWidget</string>
  <key>CFBundleDisplayName</key><string>MicLock</string>
  <key>CFBundleExecutable</key><string>MicLockWidget</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSExtension</key><dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>
  </dict>
</dict></plist>
PLIST
ICON=$(cat icon/compiled/name)
cp "icon/compiled/$ICON.icns" icon/compiled/Assets.car "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>MicLock</string>
  <key>CFBundleExecutable</key><string>MicLock</string>
  <key>CFBundleIconFile</key><string>$ICON</string>
  <key>CFBundleIconName</key><string>$ICON</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>$LABEL</string>
    <key>CFBundleURLSchemes</key><array><string>miclock</string></array>
  </dict></array>
</dict></plist>
PLIST
# Designated requirement by identifier, not cdhash: the login item survives rebuilds.
codesign --force --sign - --identifier "$LABEL.widget" --entitlements widget/Widget.entitlements "$EXT"
codesign --force --sign - --identifier "$LABEL" -r="designated => identifier \"$LABEL\"" "$APP"
echo "built $APP ($VERSION)"
