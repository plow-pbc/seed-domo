#!/usr/bin/env bash
set -euo pipefail

# Standalone Domo grand-finale flow runner.
# Calls the four solo pieces in order against one isolated DOMO_HOME.

unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

if [[ -z "${DOMO_HOME:-}" ]]; then
  DOMO_HOME="$(mktemp -d "${TMPDIR:-/tmp}/domo-flow-piece.XXXXXX")"
  CREATED_TEMP_HOME=1
else
  CREATED_TEMP_HOME=0
fi

CONFIG_DIR="$DOMO_HOME/.claude"
PLOW_STATE_FILE="$CONFIG_DIR/plow-chat/state.json"
CONNECT_URL="https://claude.ai/customize/connectors"

LOGIN_PIECE="${DOMO_FLOW_LOGIN_PIECE:-$SCRIPT_DIR/domo-login-piece.sh}"
CALENDAR_PIECE="${DOMO_FLOW_CALENDAR_PIECE:-$SCRIPT_DIR/domo-calendar-piece.sh}"
ACTIVATE_PIECE="${DOMO_FLOW_ACTIVATE_PIECE:-$SCRIPT_DIR/domo-activate-piece.sh}"
READY_PIECE="${DOMO_FLOW_READY_PIECE:-$SCRIPT_DIR/domo-ready-piece.sh}"

log() { printf '[domo-flow] %s\n' "$*"; }
err() { printf '[domo-flow] ERROR: %s\n' "$*" >&2; }

quote() {
  printf '%q' "$1"
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || {
    err "'$1' is required but not on PATH"
    exit 127
  }
}

require_piece() {
  local piece="$1" label="$2"
  [[ -x "$piece" ]] || {
    err "$label piece is missing or not executable: $piece"
    exit 1
  }
}

flow_env() {
  env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN DOMO_HOME="$DOMO_HOME" "$@"
}

wait_for_enter() {
  local prompt="$1"
  if [[ "${DOMO_FLOW_NONINTERACTIVE:-0}" == "1" ]]; then
    log "$prompt"
    log "NONINTERACTIVE=1; continuing without waiting."
    return 0
  fi
  printf '\n[domo-flow] %s\n' "$prompt"
  printf '[domo-flow] Press Enter when ready to continue. '
  IFS= read -r _ || true
}

strict_plow_state() {
  local file="$1"
  jq -e '
    type == "object"
    and (keys | sort == ["base_url", "chat_uid", "token"])
    and (.base_url | type == "string" and length > 0)
    and (.token | type == "string" and length > 0)
    and (.chat_uid | type == "string" and startswith("cht_"))
  ' "$file" >/dev/null
}

cmd_status() {
  require_tool jq
  log "DOMO_HOME=$DOMO_HOME"
  log "CLAUDE_CONFIG_DIR=$CONFIG_DIR"
  log "login_piece=$LOGIN_PIECE"
  log "calendar_piece=$CALENDAR_PIECE"
  log "activate_piece=$ACTIVATE_PIECE"
  log "ready_piece=$READY_PIECE"
  if [[ -f "$PLOW_STATE_FILE" ]] && strict_plow_state "$PLOW_STATE_FILE"; then
    log "plow_state=present chat_uid=$(jq -r '.chat_uid' "$PLOW_STATE_FILE")"
  else
    log "plow_state=missing_or_invalid"
  fi
}

cmd_flow() {
  require_tool jq
  require_piece "$LOGIN_PIECE" "login"
  require_piece "$CALENDAR_PIECE" "calendar"
  require_piece "$ACTIVATE_PIECE" "activate"
  require_piece "$READY_PIECE" "ready"

  mkdir -p "$DOMO_HOME"

  log "Grand finale starting."
  log "One isolated DOMO_HOME: $DOMO_HOME"
  log "One isolated CLAUDE_CONFIG_DIR: $CONFIG_DIR"
  if [[ "$CREATED_TEMP_HOME" == "1" ]]; then
    log "Created temp DOMO_HOME for this run."
  fi

  log "STEP 1/4 login: complete the Claude subscription login when prompted."
  flow_env "$LOGIN_PIECE" harness
  log "STEP 1/4 login: PASS"

  log "STEP 2/4 calendar: probing Google Calendar connector."
  local calendar_rc=0
  while :; do
    set +e
    flow_env "$CALENDAR_PIECE" check
    calendar_rc=$?
    set -e
    if [[ "$calendar_rc" -eq 0 ]]; then
      log "STEP 2/4 calendar: PASS"
      break
    fi
    if [[ "$calendar_rc" -eq 2 ]]; then
      err "Calendar probe says this DOMO_HOME is not logged in. Re-run the login step."
      return 2
    fi
    log "STEP 2/4 calendar: NOT_CONNECTED"
    log "Connect Google Calendar for the same Anthropic account here:"
    printf '\n  %s\n\n' "$CONNECT_URL"
    wait_for_enter "After Calendar is connected in the browser, continue to re-probe."
  done

  log "STEP 3/4 activation: real Plow solo activation."
  log "You will text the displayed code to the displayed number from the phone Domo should use."
  flow_env "$ACTIVATE_PIECE" harness
  if [[ ! -f "$PLOW_STATE_FILE" ]] || ! strict_plow_state "$PLOW_STATE_FILE"; then
    err "activation finished but state file is missing or invalid: $PLOW_STATE_FILE"
    return 1
  fi
  log "STEP 3/4 activation: PASS state_file=$PLOW_STATE_FILE"

  log "STEP 4/4 ready: author config, start daemon, send first ready text."
  flow_env "$READY_PIECE" ready
  log "STEP 4/4 ready: PASS"

  log "GRAND_FINALE_DONE"
  log "Domo should now have texted the phone used in Step 3."
}

selftest_make_shims() {
  local shim_dir="$1" call_log="$2"
  mkdir -p "$shim_dir"

  cat > "$shim_dir/login.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'login %s %s\n' "${1:-}" "$DOMO_HOME" >> "$DOMO_FLOW_CALL_LOG"
printf '[shim-login] confirmed for %s\n' "$DOMO_HOME"
SH

  cat > "$shim_dir/calendar.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
state="$DOMO_HOME/.calendar-shim-count"
count=0
[[ -f "$state" ]] && count="$(cat "$state")"
count=$((count + 1))
printf '%s\n' "$count" > "$state"
printf 'calendar %s %s count=%s\n' "${1:-}" "$DOMO_HOME" "$count" >> "$DOMO_FLOW_CALL_LOG"
if [[ "$count" -eq 1 ]]; then
  printf '[shim-calendar] NOT_CONNECTED\n'
  exit 1
fi
printf '[shim-calendar] CONNECTED\n'
SH

  cat > "$shim_dir/activate.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'activate %s %s\n' "${1:-}" "$DOMO_HOME" >> "$DOMO_FLOW_CALL_LOG"
mkdir -p "$DOMO_HOME/.claude/plow-chat"
chmod 700 "$DOMO_HOME/.claude/plow-chat"
jq -n \
  --arg base_url "http://127.0.0.1:1" \
  --arg token "flowtest_token" \
  --arg chat_uid "cht_flowtest" \
  '{base_url:$base_url, token:$token, chat_uid:$chat_uid}' \
  > "$DOMO_HOME/.claude/plow-chat/state.json"
chmod 600 "$DOMO_HOME/.claude/plow-chat/state.json"
printf '[shim-activate] VERIFIED\n'
SH

  cat > "$shim_dir/ready.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'ready %s %s\n' "${1:-}" "$DOMO_HOME" >> "$DOMO_FLOW_CALL_LOG"
jq -e '
  (keys | sort) == ["base_url","chat_uid","token"]
  and .chat_uid == "cht_flowtest"
' "$DOMO_HOME/.claude/plow-chat/state.json" >/dev/null
printf '[shim-ready] READY_TEXT_SENT\n'
SH

  chmod +x "$shim_dir/login.sh" "$shim_dir/calendar.sh" "$shim_dir/activate.sh" "$shim_dir/ready.sh"
  printf '%s\n' "$call_log" > "$shim_dir/call-log-path"
}

cmd_selftest() {
  require_tool jq
  require_piece "$ACTIVATE_PIECE" "activate"
  require_piece "$READY_PIECE" "ready"

  local root shim_dir home call_log
  root="$(mktemp -d "${TMPDIR:-/tmp}/domo-flow-selftest.XXXXXX")"
  shim_dir="$root/shims"
  home="$root/home"
  call_log="$root/calls.log"
  mkdir -p "$home"
  selftest_make_shims "$shim_dir" "$call_log"

  log "Selftest root: $root"
  DOMO_HOME="$home" \
  DOMO_FLOW_LOGIN_PIECE="$shim_dir/login.sh" \
  DOMO_FLOW_CALENDAR_PIECE="$shim_dir/calendar.sh" \
  DOMO_FLOW_ACTIVATE_PIECE="$shim_dir/activate.sh" \
  DOMO_FLOW_READY_PIECE="$shim_dir/ready.sh" \
  DOMO_FLOW_CALL_LOG="$call_log" \
  DOMO_FLOW_NONINTERACTIVE=1 \
    "$SCRIPT_PATH" flow >"$root/flow.out" 2>"$root/flow.err"

  jq -Rn '
    [inputs | split(" ")]
    | {
        commands: map(.[0]),
        domo_homes: (map(.[2]) | unique)
      }
    | .commands == ["login","calendar","calendar","activate","ready"]
      and (.domo_homes | length == 1)
  ' "$call_log" >/dev/null || {
    err "flow wiring call log failed validation"
    cat "$call_log" >&2 || true
    return 1
  }
  strict_plow_state "$home/.claude/plow-chat/state.json" || {
    err "flow did not preserve valid Piece-3 state shape"
    return 1
  }

  log "PASS flow wiring: login -> calendar retry -> activate -> ready"
  log "PASS one DOMO_HOME threaded through all piece calls: $home"

  log "Running real Piece-3 stub harness for activation mechanics."
  "$ACTIVATE_PIECE" selftest >"$root/activate-selftest.out" 2>"$root/activate-selftest.err"
  log "PASS real Piece-3 selftest"

  log "Running real Piece-4 stub harness for channel/ready mechanics."
  "$READY_PIECE" selftest >"$root/ready-selftest.out" 2>"$root/ready-selftest.err"
  log "PASS real Piece-4 selftest"

  log "Selftest artifacts: $root"
}

cmd_harness() {
  log "One-command grand finale:"
  printf '\n  DOMO_HOME=%s %s flow\n\n' "$(quote "$DOMO_HOME")" "$(quote "$SCRIPT_PATH")"
  cmd_flow "$@"
}

usage() {
  cat <<USAGE
Usage: DOMO_HOME=/one/isolated/domo-home $SCRIPT_PATH <command>

Commands:
  flow      Run login -> calendar -> real Plow activation -> ready text
  harness   Print the one-command grand finale and run flow
  status    Print non-secret flow configuration/status
  selftest  Verify runner wiring and delegate real Piece-3/Piece-4 stub harnesses

Human steps in flow:
  1. Complete Claude subscription login if Piece 1 asks.
  2. Connect Google Calendar if Piece 2 reports NOT_CONNECTED.
  3. Text one Plow activation code to the displayed number.

The same DOMO_HOME is passed to all four piece scripts.
USAGE
}

case "${1:-harness}" in
  flow) shift; cmd_flow "$@" ;;
  harness) shift; cmd_harness "$@" ;;
  status) shift; cmd_status "$@" ;;
  selftest) shift; cmd_selftest "$@" ;;
  -h|--help|help) usage ;;
  *) err "unknown command '${1:-}'"; usage >&2; exit 2 ;;
esac
