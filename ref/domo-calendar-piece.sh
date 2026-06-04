#!/usr/bin/env bash
set -euo pipefail

# Standalone Domo calendar connector check.
# Uses only an isolated Claude config dir: $DOMO_HOME/.claude.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

if [[ -z "${DOMO_HOME:-}" ]]; then
  DOMO_HOME="$(mktemp -d "${TMPDIR:-/tmp}/domo-calendar-piece.XXXXXX")"
  CREATED_TEMP_HOME=1
else
  CREATED_TEMP_HOME=0
fi

CONFIG_DIR="$DOMO_HOME/.claude"
WORKSPACE="${DOMO_CALENDAR_WORKSPACE:-$DOMO_HOME/calendar-check-workspace}"
RUN_DIR="$CONFIG_DIR/run"
CALENDAR_TOOL="mcp__claude_ai_Google_Calendar__list_calendars"
PROBE_TIMEOUT_SECONDS="${DOMO_CALENDAR_TIMEOUT_SECONDS:-90}"
WAIT_TIMEOUT_SECONDS="${DOMO_CALENDAR_WAIT_TIMEOUT_SECONDS:-600}"
WAIT_POLL_INTERVAL_SECONDS="${DOMO_CALENDAR_WAIT_POLL_INTERVAL_SECONDS:-5}"
MAX_BUDGET_USD="${DOMO_CALENDAR_MAX_BUDGET_USD:-0.50}"
CONNECT_URL="https://claude.ai/customize/connectors"

log() { printf '[domo-calendar] %s\n' "$*"; }
err() { printf '[domo-calendar] ERROR: %s\n' "$*" >&2; }

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

status_json() {
  set +e
  local out rc
  out="$(auth_env claude auth status --json 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out"
  return "$rc"
}

auth_confirmed() {
  local out rc
  set +e
  out="$(status_json)"
  rc=$?
  set -e
  [[ "$rc" -eq 0 ]] || return 1
  printf '%s' "$out" | jq -e '
    .loggedIn == true
    and .authMethod == "claude.ai"
    and .apiProvider == "firstParty"
  ' >/dev/null
}

flatten_result_text_filter='
  def flatten:
    if . == null then ""
    elif type == "string" then .
    elif type == "array" then map(flatten) | join("\n")
    elif type == "object" and (.text | type) == "string" then .text
    elif type == "object" then tostring
    else tostring
    end;
'

strict_calendar_result_confirmed() {
  local file="$1"
  CALENDAR_TOOL="$CALENDAR_TOOL" jq -s -e "$flatten_result_text_filter"'
    def content_items: .message.content? // [];
    def result_text: (.content | flatten);
    def result_structured_calendars:
      (.tool_use_result.structuredContent.calendars? // empty);
    def content_json_calendars:
      ((result_text | fromjson? | .calendars?) // empty);
    def errorish:
      (result_text | test("permission denied|not found|failed|error|missing|unauthorized|requires authentication|connect"; "i"));

    [ .[] | content_items[]? | select(.type == "tool_use" and .name == env.CALENDAR_TOOL) | .id ] as $tool_ids
    | [
        .[] | select(.type == "user") as $event
        | $event.message.content[]?
        | select(.type == "tool_result")
        | {
            tool_use_id,
            is_error,
            content,
            tool_use_result: $event.tool_use_result
          }
      ] as $tool_results
    | any(
        $tool_results[];
        (.tool_use_id as $id | ($tool_ids | index($id)) != null)
        and (.is_error != true)
        and (
          ((.tool_use_result.structuredContent.calendars? | type) == "array")
          or ((content_json_calendars | type) == "array")
          or ((result_text | length) > 2 and (errorish | not))
        )
      )
  ' "$file" >/dev/null
}

probe_calendar() {
  require_tool claude
  require_tool jq
  require_tool perl
  mkdir -p "$CONFIG_DIR" "$WORKSPACE" "$RUN_DIR"

  if ! auth_confirmed; then
    log "NOT_CONNECTED"
    log "Claude login is not confirmed for isolated config: $CONFIG_DIR"
    log "Run Piece 1 login for this DOMO_HOME first."
    return 2
  fi

  local out err rc
  out="$(mktemp "$RUN_DIR/calendar-probe.out.XXXXXX")"
  err="$(mktemp "$RUN_DIR/calendar-probe.err.XXXXXX")"

  log "DOMO_HOME=$DOMO_HOME"
  log "CLAUDE_CONFIG_DIR=$CONFIG_DIR"
  log "Workspace=$WORKSPACE"
  log "Probing $CALENDAR_TOOL with strict tool_use/tool_result linkage."

  set +e
  (
    cd "$WORKSPACE"
    auth_env perl -e 'alarm shift; exec @ARGV' "$PROBE_TIMEOUT_SECONDS" \
      claude -p --verbose --output-format stream-json \
        --permission-mode auto \
        --max-budget-usd "$MAX_BUDGET_USD" \
        "Call ${CALENDAR_TOOL} now. After the tool result returns, summarize the number of calendars. Do not claim success unless the tool result is available."
  ) >"$out" 2>"$err"
  rc=$?
  set -e

  if [[ "$rc" -eq 0 ]] && strict_calendar_result_confirmed "$out"; then
    log "CONNECTED"
    log "Confirmed linked non-error Calendar tool_result in: $out"
    return 0
  fi

  log "NOT_CONNECTED"
  log "Google Calendar connector was not confirmed for this isolated Claude account."
  log "Connect it at $CONNECT_URL on the same Anthropic account used for Domo login, then rerun this check."
  log "Probe rc=$rc stdout=$out stderr=$err"
  if [[ -s "$err" ]]; then
    sed 's/^/[domo-calendar] stderr: /' "$err" | tail -20
  fi
  return 1
}

cmd_harness() {
  log "Isolated DOMO_HOME: $DOMO_HOME"
  log "Isolated CLAUDE_CONFIG_DIR: $CONFIG_DIR"
  if [[ "$CREATED_TEMP_HOME" == "1" ]]; then
    log "Created temp DOMO_HOME for this run. Use DOMO_HOME=<piece-1-home> to check a logged-in Domo home."
  fi
  log "One-shot check command:"
  printf '\n  DOMO_HOME=%s %s check\n\n' "$(quote "$DOMO_HOME")" "$(quote "$SCRIPT_PATH")"
  probe_calendar
}

cmd_wait() {
  require_tool claude
  require_tool jq
  require_tool perl
  mkdir -p "$CONFIG_DIR" "$WORKSPACE" "$RUN_DIR"

  local start now deadline next_note probe_out probe_err rc
  start="$(date +%s)"
  deadline=$((start + WAIT_TIMEOUT_SECONDS))
  next_note="$start"
  probe_out=""
  probe_err=""

  log "Waiting up to ${WAIT_TIMEOUT_SECONDS}s for Google Calendar connector confirmation."
  log "If needed, connect Google Calendar at $CONNECT_URL for the same Anthropic account."

  while :; do
    now="$(date +%s)"
    if (( now >= deadline )); then
      err "Timed out after ${WAIT_TIMEOUT_SECONDS}s waiting for Google Calendar connector confirmation."
      err "Connect Google Calendar at $CONNECT_URL for the same Anthropic account, then rerun wait."
      if [[ -n "$probe_out" && -s "$probe_out" ]]; then
        sed 's/^/[domo-calendar] last probe: /' "$probe_out" | tail -12 >&2
      fi
      if [[ -n "$probe_err" && -s "$probe_err" ]]; then
        sed 's/^/[domo-calendar] last probe stderr: /' "$probe_err" | tail -12 >&2
      fi
      return 1
    fi

    probe_out="$(mktemp "$RUN_DIR/calendar-wait.out.XXXXXX")"
    probe_err="$(mktemp "$RUN_DIR/calendar-wait.err.XXXXXX")"
    set +e
    ( probe_calendar ) >"$probe_out" 2>"$probe_err"
    rc=$?
    set -e

    if [[ "$rc" -eq 0 ]]; then
      cat "$probe_out"
      if [[ -s "$probe_err" ]]; then
        cat "$probe_err" >&2
      fi
      return 0
    fi

    now="$(date +%s)"
    if (( now >= next_note )); then
      log "Still waiting for Google Calendar connector confirmation..."
      next_note=$((now + 30))
    fi

    sleep "$WAIT_POLL_INTERVAL_SECONDS"
  done
}

usage() {
  cat <<USAGE
Usage: DOMO_HOME=/authenticated/domo-home $SCRIPT_PATH <command>

Commands:
  check     Probe Google Calendar connector once
  wait      Block-poll connector check until CONNECTED or timeout
  harness   Print the check command, run it, and report CONNECTED/NOT_CONNECTED

If DOMO_HOME is omitted, a temp isolated home is created. For a real connector
check, pass the same DOMO_HOME that Piece 1 logged in.
USAGE
}

case "${1:-harness}" in
  check) shift; probe_calendar "$@" ;;
  wait) shift; cmd_wait "$@" ;;
  harness) shift; cmd_harness "$@" ;;
  -h|--help|help) usage ;;
  *) err "unknown command '${1:-}'"; usage >&2; exit 2 ;;
esac
