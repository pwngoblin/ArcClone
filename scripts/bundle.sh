#!/usr/bin/env bash
# Packages a release ArcClone.app into ./build. Resources are copied into
# Contents/Resources/ArcClone so AppPaths finds them without ARCCLONE_ROOT.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/ArcClone.app"
RES="$OUT/Contents/Resources/ArcClone"

[ -f "$ROOT/ui/dist/index.html" ] || { echo "ui/dist missing: run 'make ui' first" >&2; exit 1; }

(cd "$ROOT/core" && swift build -c release)
BIN="$(cd "$ROOT/core" && swift build -c release --show-bin-path)/ArcClone"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$RES/ui" "$RES/agent-bridge"
cp "$BIN" "$OUT/Contents/MacOS/ArcClone"
cp -R "$ROOT/injections" "$RES/injections"
cp -R "$ROOT/ui/dist" "$RES/ui/dist"
cp -R "$ROOT/agent-bridge/src" "$RES/agent-bridge/src"
cp "$ROOT/agent-bridge/package.json" "$RES/agent-bridge/package.json"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ArcClone</string>
  <key>CFBundleDisplayName</key><string>ArcClone</string>
  <key>CFBundleIdentifier</key><string>dev.arcclone.browser</string>
  <key>CFBundleExecutable</key><string>ArcClone</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSCameraUsageDescription</key><string>Websites you visit may request your camera.</string>
  <key>NSMicrophoneUsageDescription</key><string>Websites you visit may request your microphone.</string>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>Web URL</string>
    <key>CFBundleURLSchemes</key><array><string>http</string><string>https</string></array>
  </dict></array>
</dict>
</plist>
PLIST

codesign --force --sign - "$OUT" >/dev/null 2>&1 || echo "warning: ad-hoc codesign failed" >&2
echo "Built $OUT"
