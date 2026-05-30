#!/usr/bin/env bash
#
# run.sh — thin shim. The orchestrator is now `./domo` (channels-only Plow Chat surface
# + background daemon with session resume). This shim forwards to it so any old
# `./run.sh <cmd>` invocations keep working.
#
# Command mapping:
#   ./run.sh setup   -> ./domo setup
#   ./run.sh shell   -> ./domo shell
#   ./run.sh start   -> ./domo shell   (legacy run.sh `start` was FOREGROUND/interactive;
#                                        `./domo start` is now the BACKGROUND daemon. We
#                                        map legacy `start` to `shell` to preserve the old
#                                        foreground behavior. Use `./domo start` for the
#                                        new background daemon.)
#   ./run.sh doctor  -> ./domo doctor
# Anything else is forwarded verbatim.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMO="$SCRIPT_DIR/domo"

[[ -x "$DOMO" ]] || { printf '[run.sh] ERROR: %s not found/executable. The CLI is now ./domo.\n' "$DOMO" >&2; exit 1; }

cmd="${1:-}"
case "$cmd" in
  start)
    shift
    printf '[run.sh] NOTE: legacy `start` was foreground; forwarding to `./domo shell`.\n' >&2
    printf '[run.sh]       For the new BACKGROUND daemon use: ./domo start\n' >&2
    exec "$DOMO" shell "$@"
    ;;
  "")
    exec "$DOMO"
    ;;
  *)
    exec "$DOMO" "$@"
    ;;
esac
