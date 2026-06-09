#!/usr/bin/env bash
set -euo pipefail

# Standalone Domo login piece.
# Uses only an isolated Claude config dir: $DOMO_HOME/.claude.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

if [[ -z "${DOMO_HOME:-}" ]]; then
  DOMO_HOME="$(mktemp -d "${TMPDIR:-/tmp}/domo-login-piece.XXXXXX")"
  CREATED_TEMP_HOME=1
else
  CREATED_TEMP_HOME=0
fi

CONFIG_DIR="$DOMO_HOME/.claude"
POLL_INTERVAL_SECONDS="${DOMO_LOGIN_POLL_INTERVAL_SECONDS:-2}"
WAIT_TIMEOUT_SECONDS="${DOMO_LOGIN_WAIT_TIMEOUT_SECONDS:-600}"

log() { printf '[domo-login] %s\n' "$*"; }
err() { printf '[domo-login] ERROR: %s\n' "$*" >&2; }

quote() {
  printf '%q' "$1"
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || {
    err "'$1' is required but not on PATH"
    exit 127
  }
}

auth_env() {
  env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR="$CONFIG_DIR" "$@"
}

drain_terminal_input() {
  [[ -t 0 ]] || return 0
  local old_tty junk i=0
  old_tty="$(stty -g 2>/dev/null || true)"
  stty -icanon min 0 time 1 2>/dev/null || true
  while IFS= read -r -s -n 10000 junk; do
    i=$((i + 1))
    [[ -n "$junk" && "$i" -lt 5 ]] || break
  done
  [[ -n "$old_tty" ]] && stty "$old_tty" 2>/dev/null || true
}

login_command_text() {
  printf 'DOMO_HOME=%s %s login' "$(quote "$DOMO_HOME")" "$(quote "$SCRIPT_PATH")"
}

reset_command_text() {
  printf 'env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR=%s claude auth logout' "$(quote "$CONFIG_DIR")"
}

status_json() {
  set +e
  local out rc
  out="$(auth_env claude auth status --json 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out"
  return "$rc"
}

status_line() {
  require_tool claude
  require_tool jq
  mkdir -p "$CONFIG_DIR"

  local out rc logged_in auth_method api_provider subscription_type
  set +e
  out="$(status_json)"
  rc=$?
  set -e

  if ! printf '%s' "$out" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf '%s auth_status=unparseable rc=%s output=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" "$(printf '%s' "$out" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"
    return 2
  fi

  logged_in="$(printf '%s' "$out" | jq -r '.loggedIn // false')"
  auth_method="$(printf '%s' "$out" | jq -r '.authMethod // "missing"')"
  api_provider="$(printf '%s' "$out" | jq -r '.apiProvider // "missing"')"
  subscription_type="$(printf '%s' "$out" | jq -r '.subscriptionType // "none"')"

  printf '%s loggedIn=%s authMethod=%s apiProvider=%s subscriptionType=%s rc=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$logged_in" \
    "$auth_method" \
    "$api_provider" \
    "$subscription_type" \
    "$rc"

  if [[ "$rc" -eq 0 && "$logged_in" == "true" && "$auth_method" == "claude.ai" && "$api_provider" == "firstParty" ]]; then
    return 0
  fi
  return 1
}

auth_confirmed_quiet() {
  require_tool claude
  require_tool jq
  mkdir -p "$CONFIG_DIR"

  local out rc
  set +e
  out="$(status_json)"
  rc=$?
  set -e

  [[ "$rc" -eq 0 ]] || return 1
  printf '%s' "$out" | jq -e '
    type == "object"
    and .loggedIn == true
    and .authMethod == "claude.ai"
    and .apiProvider == "firstParty"
  ' >/dev/null
}

cmd_login() {
  require_tool claude
  mkdir -p "$CONFIG_DIR"

  log "DOMO_HOME=$DOMO_HOME"
  log "CLAUDE_CONFIG_DIR=$CONFIG_DIR"
  log "Running full Claude first-run onboarding and subscription login."
  log "Command: env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR=$(quote "$CONFIG_DIR") claude /quit"

  set +e
  auth_env claude "/quit"
  local rc=$?
  set -e

  # Claude's TUI may issue terminal queries just before exit. In some terminals the
  # delayed response bytes can reach the parent shell; drain them before restoring tty.
  drain_terminal_input
  if [[ -t 0 ]] && command -v stty >/dev/null 2>&1; then
    stty sane 2>/dev/null || true
  fi
  return "$rc"
}

cmd_status() {
  if status_line; then
    log "CONFIRMED"
    return 0
  fi
  return 1
}

cmd_wait() {
  require_tool claude
  require_tool jq
  mkdir -p "$CONFIG_DIR"

  local start now deadline next_note
  start="$(date +%s)"
  deadline=$((start + WAIT_TIMEOUT_SECONDS))
  next_note="$start"

  log "Waiting up to ${WAIT_TIMEOUT_SECONDS}s for isolated Claude subscription login to be confirmed."
  while :; do
    if auth_confirmed_quiet; then
      log "CONFIRMED"
      return 0
    fi

    now="$(date +%s)"
    if (( now >= deadline )); then
      err "Timed out after ${WAIT_TIMEOUT_SECONDS}s waiting for Claude subscription login in $CONFIG_DIR"
      err "Have the user run the login command in their own terminal, then rerun wait."
      return 1
    fi

    if (( now >= next_note )); then
      log "Still waiting for login confirmation..."
      next_note=$((now + 30))
    fi
    sleep "$POLL_INTERVAL_SECONDS"
  done
}

cmd_harness() {
  require_tool claude
  require_tool jq
  mkdir -p "$CONFIG_DIR"

  log "Isolated DOMO_HOME: $DOMO_HOME"
  log "Isolated CLAUDE_CONFIG_DIR: $CONFIG_DIR"
  if [[ "$CREATED_TEMP_HOME" == "1" ]]; then
    log "Created temp DOMO_HOME for this run."
  fi
  log "Login command to run in a real terminal:"
  printf '\n  %s\n\n' "$(login_command_text)"
  log "Reset command for this isolated config:"
  printf '\n  %s\n\n' "$(reset_command_text)"
  log "Polling auth status. Waiting for: rc=0 loggedIn=true authMethod=claude.ai apiProvider=firstParty"

  while :; do
    if status_line; then
      log "CONFIRMED"
      return 0
    fi
    sleep "$POLL_INTERVAL_SECONDS"
  done
}

cmd_logout() {
  require_tool claude
  mkdir -p "$CONFIG_DIR"
  auth_env claude auth logout
}

usage() {
  cat <<USAGE
Usage: DOMO_HOME=/isolated/domo-home $SCRIPT_PATH <command>

Commands:
  login     Run full Claude first-run onboarding/login via 'claude /quit'
  status    Poll once and print the isolated auth state
  wait      Block-poll auth status until CONFIRMED or timeout
  harness   Print login/reset commands and live-poll until login is confirmed
  logout    Run 'claude auth logout' for the isolated config

If DOMO_HOME is omitted, a temp isolated home is created.
USAGE
}

case "${1:-harness}" in
  login) shift; cmd_login "$@" ;;
  status) shift; cmd_status "$@" ;;
  wait) shift; cmd_wait "$@" ;;
  harness) shift; cmd_harness "$@" ;;
  logout) shift; cmd_logout "$@" ;;
  -h|--help|help) usage ;;
  *) err "unknown command '${1:-}'"; usage >&2; exit 2 ;;
esac
