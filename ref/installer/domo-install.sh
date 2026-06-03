#!/usr/bin/env bash
# domo-install.sh - Phase 0/1 bootstrap driver for Domo's install UX.
#
# Runs the initial no-user-interaction sequence: fail-fast tooling check,
# `domo setup`, dashboard launch, then exactly one terminal interview question.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
DOMO="${DOMO:-$REPO_ROOT/ref/domo}"
CLIENT="$HERE/client.sh"
START="$HERE/start.sh"

PROMPT="Solo or group? If group, who's in the household? (names — include yourself)"
BANNER="One quick question is waiting in your terminal — answer it to continue."

log() { printf '[domo-install] %s\n' "$*"; }
fail_tool() { printf 'missing required tool: %s\n' "$1" >&2; exit 1; }

need_tool() {
  command -v "$1" >/dev/null 2>&1 || fail_tool "$1"
}

version_ge() {
  # Compare dotted numeric versions without GNU sort -V.
  awk -v have="$1" -v need="$2" '
    BEGIN {
      split(have, h, "."); split(need, n, ".");
      for (i = 1; i <= 3; i++) {
        hv = (h[i] == "" ? 0 : h[i]) + 0;
        nv = (n[i] == "" ? 0 : n[i]) + 0;
        if (hv > nv) exit 0;
        if (hv < nv) exit 1;
      }
      exit 0;
    }'
}

check_tooling() {
  need_tool bun
  need_tool jq
  need_tool expect
  need_tool claude

  local raw version
  raw="$(claude --version 2>/dev/null | head -1 || true)"
  version="$(printf '%s' "$raw" | sed -E 's/^([0-9]+([.][0-9]+){0,2}).*/\1/')"
  [[ "$version" =~ ^[0-9]+([.][0-9]+){0,2}$ ]] || fail_tool "claude >= 2.1.80"
  version_ge "$version" "2.1.80" || fail_tool "claude >= 2.1.80"
}

dashboard_url() {
  "$CLIENT" installer_url
}

push_waiting_for_interview() {
  "$CLIENT" installer_reset "Setting up Domo"
  "$CLIENT" installer_set kicker "Preparing Domo"
  "$CLIENT" installer_set subtitle "The dashboard is ready. Answer the terminal question so setup can continue."
  "$CLIENT" installer_set message "$BANNER"
  "$CLIENT" installer_step tooling ok "Tooling check passed"
  "$CLIENT" installer_step setup ok "Domo shell prepared"
  "$CLIENT" installer_step interview waiting "$PROMPT" terminal
}

mark_interview_collected() {
  "$CLIENT" installer_set message ""
  "$CLIENT" installer_step interview ok "Household shape collected"
}

main() {
  local elapsed0 t1 t2 url answer
  elapsed0="$SECONDS"
  check_tooling
  t1="$(date +%s)"
  log "tooling-pass t=${t1} elapsed=$((SECONDS - elapsed0))s"

  "$DOMO" setup >/dev/null

  "$START" >/dev/null
  url="$(dashboard_url)"
  t2="$(date +%s)"
  log "dashboard-reachable t=${t2} elapsed-from-tooling=$((t2 - t1))s url=$url"

  push_waiting_for_interview

  printf '%s\n' "$PROMPT"
  IFS= read -r answer
  mark_interview_collected
  log "interview-collected: $answer"
}

main "$@"
