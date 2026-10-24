#!/usr/bin/env bash
# Wraps build/Lily.app in a compressed drag-to-Applications disk image.
# Usage: scripts/make-dmg.sh [output.dmg]   (run `make app` first)
# Signs the image when CODESIGN_IDENTITY names a real certificate.
set -euo pipefail
# Never trust an inherited PATH: only the system tool directories (Xcode tools are shims in /usr/bin).
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Lily.app"
VERSION="${VERSION:-$(cat "$ROOT/VERSION")}"
OUT="${1:-$ROOT/build/Lily-$VERSION.dmg}"
IDENTITY="${CODESIGN_IDENTITY:--}"

[ -d "$APP" ] || { echo "$APP missing: run 'make app' first" >&2; exit 1; }

STAGE="$(umask 077 && mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Lily.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$OUT"
hdiutil create -quiet -volname "Lily $VERSION" -srcfolder "$STAGE" -fs APFS -format ULFO -ov "$OUT"

if [ "$IDENTITY" != "-" ]; then
  codesign --force --timestamp --sign "$IDENTITY" "$OUT"
fi
echo "Built $OUT"
