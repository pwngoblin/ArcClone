#!/usr/bin/env bash
# Packages a release ArcClone.app into ./build. Resources are copied into
# Contents/Resources/ArcClone so AppPaths finds them without ARCCLONE_ROOT.
#
# Environment:
#   VERSION            marketing version (default: contents of ./VERSION)
#   BUILD_NUMBER       CFBundleVersion (default: 1)
#   UNIVERSAL=1        build arm64 + x86_64 (default: host architecture only)
#   CODESIGN_IDENTITY  signing identity, e.g. "Developer ID Application: …" (default: ad-hoc "-")
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/ArcClone.app"
RES="$OUT/Contents/Resources/ArcClone"
VERSION="${VERSION:-$(cat "$ROOT/VERSION")}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
IDENTITY="${CODESIGN_IDENTITY:--}"

ARCH_FLAGS=()
[ "${UNIVERSAL:-0}" = "1" ] && ARCH_FLAGS=(--arch arm64 --arch x86_64)
(cd "$ROOT/core" && swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"})
BIN="$(cd "$ROOT/core" && swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/ArcClone"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$RES"
cp "$BIN" "$OUT/Contents/MacOS/ArcClone"
EXE="$OUT/Contents/MacOS/ArcClone"
# Drop every rpath except the OS Swift runtime: toolchain paths baked in by the linker are a
# dylib-hijacking surface and nothing loads through @rpath.
for rpath in $(otool -l "$EXE" | awk '/cmd LC_RPATH/{getline; getline; print $2}'); do
  [ "$rpath" = "/usr/lib/swift" ] || install_name_tool -delete_rpath "$rpath" "$EXE"
done
# Keep symbols for crash reports in a dSYM next to the app (never shipped), then strip the binary.
rm -rf "$ROOT/build/ArcClone.app.dSYM"
dsymutil "$EXE" -o "$ROOT/build/ArcClone.app.dSYM" 2>/dev/null || echo "warning: dsymutil failed" >&2
strip -rSTx "$EXE"
cp -R "$ROOT/injections" "$RES/injections"
find "$OUT" -name .DS_Store -delete

ICONSET="$(mktemp -d)/AppIcon.iconset"
swift "$ROOT/scripts/make-icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$OUT/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>ArcClone</string>
  <key>CFBundleDisplayName</key><string>ArcClone</string>
  <key>CFBundleIdentifier</key><string>dev.arcclone.browser</string>
  <key>CFBundleExecutable</key><string>ArcClone</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>© $(date +%Y) ArcClone contributors</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
  <!-- Downloads carry the quarantine flag, so Gatekeeper checks downloaded apps and scripts. -->
  <key>LSFileQuarantineEnabled</key><true/>
  <key>NSCameraUsageDescription</key><string>Websites you visit may request your camera.</string>
  <key>NSMicrophoneUsageDescription</key><string>Websites you visit may request your microphone.</string>
  <!-- A browser must load any site; ATS still applies to the app's own connections. -->
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoadsInWebContent</key><true/></dict>
  <!-- Handoff: continue the active tab in Safari on another device. -->
  <key>NSUserActivityTypes</key>
  <array><string>NSUserActivityTypeBrowsingWeb</string></array>
  <!-- URL schemes plus HTML documents make ArcClone eligible as the default browser. -->
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>Web URL</string>
    <key>CFBundleURLSchemes</key><array><string>http</string><string>https</string></array>
  </dict></array>
  <key>CFBundleDocumentTypes</key>
  <array><dict>
    <key>CFBundleTypeName</key><string>HTML Document</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key>
    <array><string>public.html</string><string>public.xhtml</string></array>
  </dict></array>
</dict>
</plist>
PLIST
plutil -lint -s "$OUT/Contents/Info.plist"

SIGN_FLAGS=(--force --options runtime --entitlements "$ROOT/scripts/ArcClone.entitlements" --sign "$IDENTITY")
[ "$IDENTITY" != "-" ] && SIGN_FLAGS+=(--timestamp)
codesign "${SIGN_FLAGS[@]}" "$OUT"
"$ROOT/scripts/verify-app.sh" "$OUT"
echo "Built $OUT ($VERSION, build $BUILD_NUMBER, $(lipo -archs "$OUT/Contents/MacOS/ArcClone"))"
