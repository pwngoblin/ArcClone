#!/usr/bin/env bash
# Audits a built ArcClone.app against the project's security baseline. Run by bundle.sh and CI;
# any failure exits non-zero. Usage: scripts/verify-app.sh [path/to/ArcClone.app]
set -euo pipefail

APP="${1:-$(cd "$(dirname "$0")/.." && pwd)/build/ArcClone.app}"
BIN="$APP/Contents/MacOS/ArcClone"
PLIST="$APP/Contents/Info.plist"
failures=0
fail() { echo "✘ $*" >&2; failures=$((failures + 1)); }
pass() { echo "✔ $*"; }

# --- Signature, hardened runtime ------------------------------------------------------------
if codesign --verify --strict --deep "$APP" 2>/dev/null; then pass "signature and sealed resources verify"; else fail "codesign --verify --strict failed"; fi
flags="$(codesign -dv "$APP" 2>&1 | sed -n 's/.*flags=\(0x[0-9a-f]*\)(\(.*\)).*/\2/p')"
[[ ",$flags," == *",runtime,"* ]] && pass "hardened runtime enabled" || fail "hardened runtime missing (flags: $flags)"

# --- Entitlements: exact allowlist ----------------------------------------------------------
ALLOWED="com.apple.security.app-sandbox com.apple.security.network.client com.apple.security.files.downloads.read-write
com.apple.security.files.user-selected.read-only com.apple.security.files.bookmarks.app-scope com.apple.security.print
com.apple.security.device.camera com.apple.security.device.microphone com.apple.security.device.audio-input"
entitlements="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert json -o - - 2>/dev/null || echo '{}')"
keys="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); [print(k) for k,v in d.items() if v not in (False, [], None)]' "$entitlements")"
grep -qx "com.apple.security.app-sandbox" <<< "$keys" && pass "App Sandbox enabled" || fail "App Sandbox not enabled"
for key in $keys; do
  grep -qw -- "$key" <<< "$ALLOWED" || fail "entitlement not in allowlist: $key"
done
# Spelled out so a reviewer sees what is forbidden and why.
for key in com.apple.security.cs.disable-library-validation com.apple.security.cs.allow-dyld-environment-variables \
           com.apple.security.cs.allow-unsigned-executable-memory com.apple.security.cs.allow-jit \
           com.apple.security.cs.disable-executable-page-protection com.apple.security.get-task-allow \
           com.apple.security.network.server; do
  grep -qx -- "$key" <<< "$keys" && fail "forbidden entitlement: $key"
done
grep -q "temporary-exception" <<< "$keys" && fail "sandbox temporary exception present"
[ "$failures" -eq 0 ] && pass "entitlements match the allowlist"

# --- Dynamic library loading ----------------------------------------------------------------
rpaths="$(otool -l "$BIN" | awk '/cmd LC_RPATH/{getline; getline; print $2}' | sort -u)"
for rpath in $rpaths; do
  [ "$rpath" = "/usr/lib/swift" ] || fail "unexpected LC_RPATH: $rpath (dylib hijacking surface)"
done
deps="$(otool -L "$BIN" | tail -n +2 | awk '{print $1}')"
for dep in $deps; do
  case "$dep" in /System/*|/usr/lib/*) ;; *) fail "loads a non-system library: $dep" ;; esac
done
pass "only system libraries, no stray rpaths"

# --- Info.plist -------------------------------------------------------------------------------
plist_json="$(plutil -convert json -o - "$PLIST")"
python3 - "$plist_json" <<'PY' || failures=$((failures + 1))
import json, sys
p = json.loads(sys.argv[1])
bad = []
ats = p.get("NSAppTransportSecurity", {})
for key in ("NSAllowsArbitraryLoads", "NSAllowsArbitraryLoadsForMedia", "NSExceptionDomains"):
    if ats.get(key):
        bad.append(f"ATS {key} weakens the app's own connections")
if "LSEnvironment" in p:
    bad.append("LSEnvironment can inject environment variables")
for key in ("NSAppleScriptEnabled", "OSAScriptingDefinition"):
    if p.get(key):
        bad.append(f"{key} exposes a scripting interface other apps could drive")
if not p.get("LSFileQuarantineEnabled"):
    bad.append("LSFileQuarantineEnabled must be true")
for b in bad:
    print(f"✘ Info.plist: {b}", file=sys.stderr)
if not bad:
    print("✔ Info.plist: ATS limited to web content, no LSEnvironment, downloads quarantined")
sys.exit(1 if bad else 0)
PY

# --- Reverse engineering: symbols and secrets -------------------------------------------------
if nm -ap "$BIN" 2>/dev/null | grep -q " OSO "; then fail "debug map (N_OSO) left in binary: run strip"; else pass "debug symbols stripped"; fi
SECRET_RE='AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{36}|xox[baprs]-[A-Za-z0-9-]{10,}'
if { strings -a "$BIN"; find "$APP/Contents/Resources" -type f -print0 | xargs -0 cat; } 2>/dev/null | grep -Eq "$SECRET_RE"; then
  fail "something that looks like a secret is embedded in the app"
else
  pass "no embedded secrets found"
fi

if [ "$failures" -gt 0 ]; then
  echo "verify-app: $failures problem(s) in $APP" >&2
  exit 1
fi
echo "verify-app: $APP passes the security baseline"
