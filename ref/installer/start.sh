#!/usr/bin/env bash
# start.sh — bring up the install dashboard in ONE command: launch the server
# (detached, so it survives across a driver's separate shells), wait for it, open
# the browser, and print how to drive it. Agent/SEED-agnostic.
#
#   ref/installer/start.sh
#   # → opens http://127.0.0.1:PORT in the browser; then drive it with one-liners:
#   ref/installer/client.sh installer_reset "Setting up Domo"
#   ref/installer/client.sh installer_step  login waiting "Sign in" terminal "domo login"
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v bun >/dev/null 2>&1 || { echo "start.sh: 'bun' not on PATH" >&2; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "start.sh: 'jq' not on PATH" >&2; exit 1; }

INSTALLER_STATE_DIR="${INSTALLER_STATE_DIR:-${TMPDIR:-/tmp}/installer-ui}"
export INSTALLER_STATE_DIR
mkdir -p "$INSTALLER_STATE_DIR"
INFO="$INSTALLER_STATE_DIR/server-info"

# Already running? Reuse it.
if [ -f "$INFO" ] && curl -sS -m2 "$(jq -r '.url + "/healthz"' "$INFO" 2>/dev/null)" >/dev/null 2>&1; then
  URL="$(jq -r .url "$INFO")"
  echo "Install dashboard already up: $URL"
else
  rm -f "$INFO"
  nohup bun run "$HERE/server.ts" >"$INSTALLER_STATE_DIR/server.log" 2>&1 &
  for _ in $(seq 1 40); do [ -f "$INFO" ] && break; sleep 0.25; done
  [ -f "$INFO" ] || { echo "start.sh: server did not come up — see $INSTALLER_STATE_DIR/server.log" >&2; exit 1; }
  URL="$(jq -r .url "$INFO")"
  echo "Install dashboard up: $URL"
fi

# Open the user's browser (macOS `open`; otherwise print the URL to share).
# Drivers can set INSTALLER_NO_OPEN=1 when they need to push initial state before
# first paint, then open the URL themselves.
if [ "${INSTALLER_NO_OPEN:-0}" != "1" ]; then
  if command -v open >/dev/null 2>&1; then open "$URL" >/dev/null 2>&1 || true
  else echo "Open this in your browser: $URL"; fi
fi

cat <<EOF
Drive it with one-liners (no JSON needed):
  $HERE/client.sh installer_reset "Setting up Domo"
  $HERE/client.sh installer_step  <id> <status> [label] [where] [command|link]
  $HERE/client.sh installer_verify <name> <status> [code] [number] [self]
  $HERE/client.sh installer_done  "Domo is live — text +1555… to talk to it"
EOF
