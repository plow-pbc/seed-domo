#!/usr/bin/env bash
# domo-install.sh - Phase 0/1 bootstrap driver for Domo's install UX.
#
# Runs the initial no-user-interaction sequence: fail-fast tooling check,
# `domo setup`, dashboard launch, then exactly one terminal interview question.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
DOMO_HOME="${DOMO_HOME:-$REPO_ROOT}"
export DOMO_HOME
DOMO="${DOMO:-$REPO_ROOT/ref/domo}"
CLIENT="$HERE/client.sh"
START="$HERE/start.sh"
INSTALL_STATE_FILE="$DOMO_HOME/install-state.json"

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
  raw="$(claude --version 2>/dev/null || true)"
  if [[ "$raw" =~ ([0-9]+([.][0-9]+){0,2}) ]]; then
    version="${BASH_REMATCH[1]}"
  else
    fail_tool "claude >= 2.1.80"
  fi
  version_ge "$version" "2.1.80" || fail_tool "claude >= 2.1.80"
}

prepare_installer_state_dir() {
  if [ -z "${INSTALLER_STATE_DIR:-}" ]; then
    INSTALLER_STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/domo-installer-ui.XXXXXX")"
  else
    mkdir -p "$INSTALLER_STATE_DIR"
    rm -f "$INSTALLER_STATE_DIR/server-info" "$INSTALLER_STATE_DIR/state.json"
  fi
  export INSTALLER_STATE_DIR
}

dashboard_url() {
  "$CLIENT" installer_url
}

open_dashboard() {
  local url="$1"
  [ "${INSTALLER_NO_OPEN:-0}" = "1" ] && return 0
  if command -v open >/dev/null 2>&1; then
    open "$url" >/dev/null 2>&1 || true
  else
    printf 'Open this in your browser: %s\n' "$url"
  fi
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

persist_interview() {
  local answer="$1"
  local mode="solo"
  if [[ "$answer" =~ [Gg][Rr][Oo][Uu][Pp] ]]; then
    mode="group"
  fi

  local names="$answer"
  if [ "$mode" = "group" ]; then
    if [[ "$names" == *:* ]]; then
      names="${names#*:}"
    else
      names="${names#[Gg][Rr][Oo][Uu][Pp]}"
    fi
  else
    names=""
  fi

  mkdir -p "$DOMO_HOME"
  local tmp
  tmp="$(umask 077; mktemp "$DOMO_HOME/.install-state.json.XXXXXX")"
  jq -n --arg mode "$mode" --arg raw "$names" '
    {
        interview: {
          mode: $mode,
          members: (
            if $mode == "group" then
              ($raw
                | gsub("[\r\n]+"; " ")
                | split(",")
                | map(gsub("^\\s+|\\s+$"; ""))
                | map(select(length > 0)))
            else [] end
          )
        }
      }
  ' > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$INSTALL_STATE_FILE"
}

interview_summary() {
  jq -r '
    .interview.mode as $mode
    | (.interview.members // [] | length) as $count
    | if $mode == "group" then
        "interview: collected (mode=group, \($count) members)"
      else
        "interview: collected (mode=solo)"
      end
  ' "$INSTALL_STATE_FILE"
}

main() {
  local elapsed0 t1 t2 url answer
  elapsed0="$SECONDS"
  check_tooling
  t1="$(date +%s)"
  log "tooling-pass t=${t1} elapsed=$((SECONDS - elapsed0))s"

  prepare_installer_state_dir

  "$DOMO" setup >/dev/null 2>&1

  INSTALLER_NO_OPEN=1 "$START" >/dev/null
  url="$(dashboard_url)"
  push_waiting_for_interview
  open_dashboard "$url"
  t2="$(date +%s)"
  log "dashboard-reachable t=${t2} elapsed-from-tooling=$((t2 - t1))s url=$url"

  printf '%s\n' "$PROMPT"
  IFS= read -r answer
  persist_interview "$answer"
  mark_interview_collected
  log "$(interview_summary)"
}

main "$@"
