#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Usage:
#   ./run-pingcastle-audit.sh [path/to/PingCastle.exe]
#
# Optional reduced probe mode:
#   SAFE_MODE=true ./run-pingcastle-audit.sh [path/to/PingCastle.exe]

SERVER="${SERVER:-srvdcp.bmcek.intranet}"
USER_UPN="${USER_UPN:-saad.ineos@bmcek.co.ma}"
PROTOCOL="${PROTOCOL:-LDAPOnly}"
SAFE_MODE="${SAFE_MODE:-false}"
WINE_DEBUG="${WINE_DEBUG:-err+all}"
EXE_INPUT="${1:-./pingcastle/PingCastle.exe}"

if [[ ! -f "$EXE_INPUT" ]]; then
  printf 'ERROR: PingCastle executable not found: %s\n' "$EXE_INPUT" >&2
  printf 'Usage: %s /full/path/to/PingCastle.exe\n' "$0" >&2
  exit 1
fi

EXE_DIR="$(cd "$(dirname "$EXE_INPUT")" && pwd)"
EXE_NAME="$(basename "$EXE_INPUT")"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
CONSOLE_LOG="$EXE_DIR/pingcastle-wrapper-${RUN_ID}.log"
HELP_LOG="$(mktemp)"
MARKER="$(mktemp "$EXE_DIR/.pingcastle-start.XXXXXX")"
PC_PASSWORD=""

cleanup() {
  PC_PASSWORD=""
  unset PC_PASSWORD
  rm -f "$HELP_LOG" "$MARKER"
}
trap cleanup EXIT HUP INT TERM

if command -v wine >/dev/null 2>&1; then
  WINE_BIN="wine"
elif command -v wine64 >/dev/null 2>&1; then
  WINE_BIN="wine64"
else
  printf 'ERROR: Wine is not installed. Run: sudo apt update && sudo apt install -y wine wine64\n' >&2
  exit 2
fi

printf 'PingCastle audit preflight\n'
printf '  UTC run ID: %s\n' "$RUN_ID"
printf '  Wine:       %s\n' "$($WINE_BIN --version 2>&1)"
printf '  Executable: %s/%s\n' "$EXE_DIR" "$EXE_NAME"
printf '  Server:     %s\n' "$SERVER"
printf '  User:       %s\n' "$USER_UPN"
printf '  Protocol:   %s\n' "$PROTOCOL"

if ! getent hosts "$SERVER"; then
  printf 'ERROR: %s does not resolve. Check internal DNS or /etc/hosts.\n' "$SERVER" >&2
  exit 3
fi

if command -v nc >/dev/null 2>&1; then
  for port in 88 389 445; do
    if nc -z -w 3 "$SERVER" "$port" >/dev/null 2>&1; then
      printf '  TCP/%s:      reachable\n' "$port"
    else
      printf '  TCP/%s:      not reachable (some checks may be incomplete)\n' "$port" >&2
    fi
  done
else
  printf '  Note: netcat is unavailable; skipping port preflight.\n'
fi

printf '\nChecking whether PingCastle starts under Wine...\n'
(
  cd "$EXE_DIR"
  WINEDEBUG="$WINE_DEBUG" timeout 30 "$WINE_BIN" "$EXE_NAME" --help
) >"$HELP_LOG" 2>&1 || true

if ! grep -qi -- '--healthcheck' "$HELP_LOG"; then
  printf 'ERROR: PingCastle did not produce its CLI help. Wine may be incompatible.\n' >&2
  printf '%s\n' '--- Wine/PingCastle diagnostic output ---' >&2
  sed -n '1,160p' "$HELP_LOG" >&2
  exit 4
fi
printf '  PingCastle startup: OK\n'

printf '\nThe password will not be written to shell history.\n'
printf 'WARNING: PingCastle only accepts explicit Linux/Wine credentials as a process argument.\n'
printf '         A privileged local process could see it briefly while the audit runs.\n'
read -r -s -p "Password for ${USER_UPN}: " PC_PASSWORD
printf '\n'
[[ -n "$PC_PASSWORD" ]] || { printf 'ERROR: Empty password.\n' >&2; exit 5; }

ARGS=(
  "$WINE_BIN" "$EXE_NAME"
  --healthcheck
  --server "$SERVER"
  --protocol "$PROTOCOL"
  --user "$USER_UPN"
  --password "$PC_PASSWORD"
  --datefile
  --log
  --log-console
)

if [[ "$SAFE_MODE" == "true" ]]; then
  ARGS+=(--skip-null-session --skip-dc-rpc)
  printf 'Reduced probe mode enabled: null-session and DC RPC tests will be skipped.\n'
fi

printf 'Starting PingCastle. Console log: %s\n' "$CONSOLE_LOG"
set +e
(
  cd "$EXE_DIR"
  WINEDEBUG="$WINE_DEBUG" "${ARGS[@]}"
) 2>&1 | tee "$CONSOLE_LOG"
PC_EXIT=${PIPESTATUS[0]}
set -e

PC_PASSWORD=""
unset PC_PASSWORD

printf '\nPingCastle exit code: %s\n' "$PC_EXIT"
printf 'Files created or updated during this run:\n'
mapfile -t RESULTS < <(
  find "$EXE_DIR" -maxdepth 1 -type f -newer "$MARKER" \
    \( -iname '*.html' -o -iname '*.xml' -o -iname '*.json' -o -iname '*.log' \) \
    -printf '%f\n' | sort
)
printf '  %s\n' "${RESULTS[@]:-none}"

if [[ $PC_EXIT -ne 0 ]]; then
  printf 'ERROR: PingCastle failed. Review %s\n' "$CONSOLE_LOG" >&2
  exit "$PC_EXIT"
fi

if ! printf '%s\n' "${RESULTS[@]:-}" | grep -Eqi '\.(html|xml)$'; then
  printf 'ERROR: PingCastle exited without producing an HTML/XML report.\n' >&2
  printf 'Review the console log. An old Wine build or failed credential prompt is likely.\n' >&2
  exit 6
fi

printf 'Audit collection completed. Protect the reports as sensitive AD evidence.\n'

