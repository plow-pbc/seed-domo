#!/usr/bin/env bash
# Deterministic verification runner for the SEED-driven Domo install.
#
# The install path is the root SEED.md action: an installing agent runs the four
# verified pieces with DOMO_HOME=$HOME/.domo. This script covers the parts that
# can be tested without a human Claude login, Calendar connector, or live SMS.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

log() { printf '[verify] %s\n' "$*"; }
fail() { printf '[verify] FAIL: %s\n' "$*" >&2; exit 1; }

need_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required tool: $1"
}

need_tool bash
need_tool bun
need_tool jq
need_tool curl

cd "$REPO_ROOT"

log "structural SEED checks"
bash ref/verify.sh

log "activation piece selftest"
ref/domo-activate-piece.sh selftest

log "ready piece selftest"
ref/domo-ready-piece.sh selftest

log "all deterministic install checks passed"
