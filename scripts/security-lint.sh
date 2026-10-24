#!/usr/bin/env bash
# Static security checks for the source tree, run before every commit (.githooks/pre-commit)
# and in CI (`make check`). Each rule mirrors one in CLAUDE.md; any hit fails with file:line.
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
failures=0
report() { # report "rule" <matches>
  if [ -n "$2" ]; then
    echo "✘ $1" >&2
    printf '%s\n' "$2" | sed 's/^/    /' >&2
    failures=$((failures + 1))
  else
    echo "✔ $1"
  fi
}
swift_sources() { git ls-files -- 'core/Sources/*.swift'; }
scan() { # scan <regex> <files…>: grep -nE over the listed files, empty when none match
  [ "$#" -gt 1 ] || return 0
  local regex="$1"; shift
  grep -nE -- "$regex" "$@" 2>/dev/null || true
}

mapfile_compat() { local IFS=$'\n'; set -f; FILES=($1); set +f; }
mapfile_compat "$(swift_sources)"
SWIFT=("${FILES[@]}")
mapfile_compat "$(git ls-files -- 'injections/*.js')"
JS=("${FILES[@]}")
mapfile_compat "$(git ls-files -- 'scripts/*.sh' '.githooks/*')"
SHELL_SCRIPTS=("${FILES[@]}")

report "no print/NSLog/debugPrint/dump in app code (use os.Logger)" \
  "$(scan '(^|[^.[:alnum:]_])(print|NSLog|debugPrint|dump)\(' "${SWIFT[@]}")"

report "no shell or process spawning (system, popen, NSTask, Process)" \
  "$(scan '(^|[^.[:alnum:]_])(system|popen|posix_spawn)\(|NSTask|(^|[^.[:alnum:]_])Process\(' "${SWIFT[@]}")"

report "no unsafe pointer types" \
  "$(scan 'Unsafe(Mutable)?(Raw)?(Buffer)?Pointer|unsafeBitCast|Unmanaged<' "${SWIFT[@]}")"

xpc=""
for file in "${SWIFT[@]}"; do
  if grep -q "NSXPCConnection" "$file" && ! grep -q "setCodeSigningRequirement" "$file"; then xpc+="$file: NSXPCConnection without setCodeSigningRequirement"$'\n'; fi
done
report "XPC connections validate the peer's code signature" "${xpc%$'\n'}"

report "log interpolations carry an explicit privacy qualifier" \
  "$( { [ "${#SWIFT[@]}" -gt 0 ] && grep -nE 'Log\.[a-z]+\.(debug|info|notice|error|fault|warning)\(' "${SWIFT[@]}" || true; } \
      | perl -ne 'my $n = () = /\\\(/g; my $p = () = /privacy:/g; print if $n > $p')"

report "injected scripts: no eval, Function, innerHTML/outerHTML, document.write, string timers, setInterval" \
  "$(scan '(^|[^.[:alnum:]_])eval\(|new Function\(|\.(inner|outer)HTML[[:space:]]*=|insertAdjacentHTML|document\.write|set(Timeout|Interval)\([[:space:]]*["'"'"'`]|setInterval\(' "${JS[@]}")"

report "package dependencies pinned to exact versions or revisions" \
  "$(grep -nE '\.package\(' core/Package.swift | grep -vE 'exact:|revision:' || true)"

report "no committed secrets" \
  "$(git ls-files -z | xargs -0 grep -nIE 'AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{40,}|sk-[A-Za-z0-9_-]{32,}|xox[baprs]-[A-Za-z0-9-]{10,}' 2>/dev/null \
      | grep -vE '^(scripts/verify-app\.sh|scripts/security-lint\.sh):' || true)"

guard=""
for file in "${SHELL_SCRIPTS[@]}"; do
  head -15 "$file" | grep -q '^set -euo pipefail' || guard+="$file: missing set -euo pipefail"$'\n'
  grep -qE '^export PATH="/usr/bin:/bin:/usr/sbin:/sbin"' "$file" || guard+="$file: PATH not locked down"$'\n'
  if grep -q 'mktemp' "$file" && ! grep -q 'umask 077' "$file"; then guard+="$file: mktemp without umask 077"$'\n'; fi
done
report "shell scripts: strict mode, fixed PATH, private temp files" "${guard%$'\n'}"

if [ "$failures" -gt 0 ]; then
  echo "security-lint: $failures check(s) failed" >&2
  exit 1
fi
echo "security-lint: all checks passed"
