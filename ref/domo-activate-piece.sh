#!/usr/bin/env bash
set -euo pipefail

# Standalone Domo solo Plow activation piece.
# Uses only an isolated Claude config dir: $DOMO_HOME/.claude.

unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

if [[ -z "${DOMO_HOME:-}" ]]; then
  DOMO_HOME="$(mktemp -d "${TMPDIR:-/tmp}/domo-activate-piece.XXXXXX")"
  CREATED_TEMP_HOME=1
else
  CREATED_TEMP_HOME=0
fi

CONFIG_DIR="$DOMO_HOME/.claude"
PLOW_DIR="$CONFIG_DIR/plow-chat"
PLOW_STATE_FILE="$PLOW_DIR/state.json"
PLOW_ACTIVATION_FILE="$PLOW_DIR/activation.json"
PLOW_BASE_URL="${PLOW_CHAT_BASE_URL:-https://api.plow.co}"
ACTIVATION_TIMEOUT_SECONDS="${DOMO_ACTIVATION_TIMEOUT_SECONDS:-300}"
ACTIVATION_POLL_INTERVAL_SECONDS="${DOMO_ACTIVATION_POLL_INTERVAL_SECONDS:-3}"
PLOW_STUB="$SCRIPT_DIR/installer/plow-stub.ts"

TMP_FILES=()
PIDS=()

log() { printf '[domo-activate] %s\n' "$*"; }
err() { printf '[domo-activate] ERROR: %s\n' "$*" >&2; }

quote() {
  printf '%q' "$1"
}

cleanup() {
  local pid
  if ((${#PIDS[@]})); then
    for pid in "${PIDS[@]}"; do
      kill "$pid" >/dev/null 2>&1 || true
    done
  fi
  if ((${#TMP_FILES[@]})); then
    rm -f "${TMP_FILES[@]}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

require_tool() {
  command -v "$1" >/dev/null 2>&1 || {
    err "'$1' is required but not on PATH"
    exit 127
  }
}

int_or_default() {
  local raw="$1" default="$2"
  [[ "$raw" =~ ^[0-9]+$ ]] && printf '%s' "$raw" || printf '%s' "$default"
}

file_mode() {
  local path="$1"
  stat -f '%Lp' "$path" 2>/dev/null || stat -c '%a' "$path" 2>/dev/null || printf 'unknown'
}

setup_plow_dir() {
  mkdir -p "$PLOW_DIR"
  chmod 700 "$PLOW_DIR"
}

json_get() {
  local path="$1"
  jq -r "$path // empty"
}

strict_activation_response() {
  jq -e '
    type == "object"
    and (.activation_secret | type == "string" and length > 0)
    and (.display_code | type == "string" and length > 0)
    and (.send_to | type == "string" and length > 0)
  ' >/dev/null
}

strict_redeem_response() {
  jq -e '
    type == "object"
    and (
      .status == "pending"
      or (
        .status == "verified"
        and (.token | type == "string" and length > 0)
        and (.chat.uid | type == "string" and startswith("cht_"))
      )
    )
  ' >/dev/null
}

strict_state_file() {
  local file="$1"
  jq -e '
    type == "object"
    and (keys | sort == ["base_url", "chat_uid", "token"])
    and (.base_url | type == "string" and length > 0)
    and (.token | type == "string" and length > 0)
    and (.chat_uid | type == "string" and startswith("cht_"))
  ' "$file" >/dev/null
}

plow_http() {
  local method="$1" path="$2" body="${3:-}" token="${4:-}" expect_json="${5:-1}"
  local url="${PLOW_BASE_URL%/}$path" out err_file config="" code rc
  out="$(mktemp "${TMPDIR:-/tmp}/domo-plow-body.XXXXXX")"
  err_file="$(mktemp "${TMPDIR:-/tmp}/domo-plow-err.XXXXXX")"
  TMP_FILES+=("$out" "$err_file")

  local args=(-sS -o "$out" -w "%{http_code}" -X "$method" "$url" -H 'Content-Type: application/json')
  if [[ -n "$token" ]]; then
    config="$(umask 077; mktemp "${TMPDIR:-/tmp}/domo-plow-curl.XXXXXX")"
    TMP_FILES+=("$config")
    jq -rn --arg token "$token" '"header = \"Authorization: Bearer \($token)\"\n"' > "$config"
    chmod 600 "$config"
    args+=(--config "$config")
  fi

  set +e
  if [[ "$method" == "GET" || "$method" == "DELETE" ]]; then
    code="$(curl "${args[@]}" 2>"$err_file")"
    rc=$?
  else
    code="$(printf '%s' "$body" | curl "${args[@]}" --data-binary @- 2>"$err_file")"
    rc=$?
  fi
  set -e

  if [[ "$rc" -ne 0 ]]; then
    local msg
    msg="$(tr '\n' ' ' < "$err_file" | sed 's/[[:space:]]\+/ /g')"
    err "Plow API $method $path failed: ${msg:-curl exit $rc}"
    return "$rc"
  fi
  if [[ ! "$code" =~ ^[0-9][0-9][0-9]$ || "$code" -lt 200 || "$code" -ge 300 ]]; then
    local response
    response="$(tr '\n' ' ' < "$out" | sed 's/[[:space:]]\+/ /g')"
    err "Plow API $method $path returned HTTP ${code:-000}: ${response:-<empty response>}"
    return 1
  fi
  if [[ "$expect_json" == "1" ]]; then
    if ! jq -e . "$out" >/dev/null 2>"$err_file"; then
      local parse_err response
      parse_err="$(tr '\n' ' ' < "$err_file" | sed 's/[[:space:]]\+/ /g')"
      response="$(tr '\n' ' ' < "$out" | sed 's/[[:space:]]\+/ /g')"
      err "Plow API $method $path returned invalid JSON: ${parse_err:-parse failed}; body=${response:-<empty>}"
      return 1
    fi
  fi
  cat "$out"
}

write_activation_file() {
  local response="$1" tmp
  tmp="$(umask 077; mktemp "$PLOW_DIR/.activation.json.XXXXXX")"
  TMP_FILES+=("$tmp")
  printf '%s' "$response" | jq --arg base_url "${PLOW_BASE_URL%/}" '
    {
      base_url: $base_url,
      activation_secret: .activation_secret,
      display_code: .display_code,
      send_to: .send_to,
      line_uid: (.line_id // .line_uid // null)
    }
  ' > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$PLOW_ACTIVATION_FILE"
}

write_state_file() {
  local token="$1" chat_uid="$2" tmp
  tmp="$(umask 077; mktemp "$PLOW_DIR/.state.json.XXXXXX")"
  TMP_FILES+=("$tmp")
  jq -n --arg base_url "${PLOW_BASE_URL%/}" --arg token "$token" --arg chat_uid "$chat_uid" '
    {
      base_url: $base_url,
      token: $token,
      chat_uid: $chat_uid
    }
  ' > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$PLOW_STATE_FILE"
}

poll_activation_redeem() {
  local activation_secret="$1"
  local deadline=$(( $(date +%s) + $(int_or_default "$ACTIVATION_TIMEOUT_SECONDS" 300) ))
  local interval status payload redeem
  interval="$(int_or_default "$ACTIVATION_POLL_INTERVAL_SECONDS" 3)"

  while :; do
    payload="$(jq -n --arg activation_secret "$activation_secret" '{activation_secret: $activation_secret}')"
    redeem="$(plow_http POST /v1/auth/activate/redeem "$payload")"
    if ! printf '%s' "$redeem" | strict_redeem_response; then
      err "activation redeem response failed strict validation"
      return 1
    fi

    status="$(printf '%s' "$redeem" | json_get '.status')"
    if [[ "$status" == "verified" ]]; then
      printf '%s' "$redeem"
      return 0
    fi
    [[ "$status" == "pending" ]] || {
      err "activation redeem returned unexpected status '$status'"
      return 1
    }
    if [[ "$(date +%s)" -ge "$deadline" ]]; then
      err "activation still pending after ${ACTIVATION_TIMEOUT_SECONDS}s"
      return 75
    fi
    sleep "$interval"
  done
}

activation_command_text() {
  printf 'DOMO_HOME=%s %s activate' "$(quote "$DOMO_HOME")" "$(quote "$SCRIPT_PATH")"
}

cleanup_command_text() {
  printf 'DOMO_HOME=%s %s cleanup' "$(quote "$DOMO_HOME")" "$(quote "$SCRIPT_PATH")"
}

cmd_activate() {
  local force=0
  if [[ "${1:-}" == "--force" ]]; then
    force=1
  fi

  require_tool curl
  require_tool jq
  setup_plow_dir

  if [[ "$force" -eq 0 && -f "$PLOW_STATE_FILE" ]] && strict_state_file "$PLOW_STATE_FILE"; then
    log "already activated (state.json has a valid token). Use 'activate --force' to redo."
    return 0
  fi

  log "DOMO_HOME=$DOMO_HOME"
  log "CLAUDE_CONFIG_DIR=$CONFIG_DIR"
  log "Requesting solo Plow activation at ${PLOW_BASE_URL%/} ..."

  local response activation_secret display_code send_to line_uid
  response="$(plow_http POST /v1/auth/activate '{"name":"Domo","provision_chat":true}')"
  if ! printf '%s' "$response" | strict_activation_response; then
    err "activation response failed strict validation"
    return 1
  fi

  activation_secret="$(printf '%s' "$response" | json_get '.activation_secret')"
  display_code="$(printf '%s' "$response" | json_get '.display_code')"
  send_to="$(printf '%s' "$response" | json_get '.send_to')"
  line_uid="$(printf '%s' "$response" | json_get '.line_id // .line_uid')"
  write_activation_file "$response"

  cat >&2 <<EOF

[domo-activate] ============================================================
[domo-activate] PLOW SOLO ACTIVATION - ACTION REQUIRED
[domo-activate] ============================================================
[domo-activate] From the phone you want bound to Domo, text EXACTLY:
[domo-activate]
[domo-activate]     $display_code
[domo-activate]
[domo-activate]   to:  $send_to
[domo-activate]
[domo-activate] (line: ${line_uid:-unknown}) Polling for verification up to ${ACTIVATION_TIMEOUT_SECONDS}s...
[domo-activate] ============================================================
EOF

  local redeem token chat_uid
  redeem="$(poll_activation_redeem "$activation_secret")"
  token="$(printf '%s' "$redeem" | json_get '.token')"
  chat_uid="$(printf '%s' "$redeem" | json_get '.chat.uid')"

  write_state_file "$token" "$chat_uid"
  rm -f "$PLOW_ACTIVATION_FILE"

  if ! strict_state_file "$PLOW_STATE_FILE"; then
    err "written state file failed strict validation"
    return 1
  fi
  log "VERIFIED"
  log "State written to $PLOW_STATE_FILE (chmod $(file_mode "$PLOW_STATE_FILE")). chat_uid=$chat_uid"
  log "Token stored (NOT printed)."
}

cmd_harness() {
  log "Isolated DOMO_HOME: $DOMO_HOME"
  log "Isolated CLAUDE_CONFIG_DIR: $CONFIG_DIR"
  log "Plow base_url: ${PLOW_BASE_URL%/}"
  if [[ "$CREATED_TEMP_HOME" == "1" ]]; then
    log "Created temp DOMO_HOME for this run."
  fi
  log "One-command real activation harness:"
  printf '\n  DOMO_HOME=%s %s harness\n\n' "$(quote "$DOMO_HOME")" "$(quote "$SCRIPT_PATH")"
  log "Cleanup command after real verification:"
  printf '\n  %s\n\n' "$(cleanup_command_text)"
  cmd_activate "$@"
}

cmd_status() {
  require_tool jq
  setup_plow_dir
  if [[ ! -f "$PLOW_STATE_FILE" ]]; then
    log "NOT_ACTIVATED state_file=$PLOW_STATE_FILE"
    return 1
  fi
  if ! strict_state_file "$PLOW_STATE_FILE"; then
    log "INVALID state_file=$PLOW_STATE_FILE"
    return 2
  fi
  local base_url chat_uid mode
  base_url="$(jq -r '.base_url' "$PLOW_STATE_FILE")"
  chat_uid="$(jq -r '.chat_uid' "$PLOW_STATE_FILE")"
  mode="$(file_mode "$PLOW_STATE_FILE")"
  log "ACTIVATED base_url=$base_url chat_uid=$chat_uid state_file=$PLOW_STATE_FILE mode=$mode"
  [[ "$mode" == "600" ]] || {
    err "state file mode is $mode, expected 600"
    return 1
  }
}

cmd_cleanup() {
  require_tool curl
  require_tool jq
  setup_plow_dir
  if [[ ! -f "$PLOW_STATE_FILE" ]]; then
    log "No Plow state file to clean up: $PLOW_STATE_FILE"
    return 0
  fi
  strict_state_file "$PLOW_STATE_FILE" || {
    err "cannot cleanup invalid state file"
    return 1
  }

  local base_url token chat_uid
  base_url="$(jq -r '.base_url' "$PLOW_STATE_FILE")"
  token="$(jq -r '.token' "$PLOW_STATE_FILE")"
  chat_uid="$(jq -r '.chat_uid' "$PLOW_STATE_FILE")"
  [[ "$chat_uid" =~ ^cht_[A-Za-z0-9_-]+$ ]] || {
    err "invalid chat_uid in state file"
    return 1
  }

  PLOW_BASE_URL="$base_url"
  log "Soft-deleting Plow chat $chat_uid at ${PLOW_BASE_URL%/} ..."
  plow_http DELETE "/v1/chats/$chat_uid" "" "$token" 0 >/dev/null
  rm -f "$PLOW_STATE_FILE" "$PLOW_ACTIVATION_FILE"
  log "CLEANED_UP chat_uid=$chat_uid local_state_removed=true"
}

wait_for_file() {
  local file="$1" timeout="$2"
  local deadline=$(( $(date +%s) + timeout ))
  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    [[ -s "$file" ]] && return 0
    sleep 0.2
  done
  return 1
}

auto_text_stub_code() {
  local base_url="$1" activation_file="$2" seen_file="$3"
  local code
  while :; do
    if [[ -f "$activation_file" ]]; then
      code="$(jq -r '.display_code // empty' "$activation_file" 2>/dev/null || true)"
      if [[ -n "$code" ]] && ! grep -qxF "$code" "$seen_file" 2>/dev/null; then
        printf '%s\n' "$code" >> "$seen_file"
        jq -n --arg text "$code" '{text: $text}' \
          | curl -fsS -X POST "$base_url/_stub/text" -H 'Content-Type: application/json' -d @- >/dev/null
        return 0
      fi
    fi
    sleep 0.2
  done
}

cmd_selftest() {
  require_tool bun
  require_tool curl
  require_tool jq
  [[ -f "$PLOW_STUB" ]] || {
    err "stub not found at $PLOW_STUB"
    return 1
  }

  local root stub_dir home server_info base_url state_file calls_file out_file err_file text_pid activate_rc
  root="$(mktemp -d "${TMPDIR:-/tmp}/domo-activate-selftest.XXXXXX")"
  stub_dir="$root/stub"
  home="$root/home"
  server_info="$stub_dir/server-info"
  state_file="$home/.claude/plow-chat/state.json"
  calls_file="$root/calls.json"
  out_file="$root/activate.out"
  err_file="$root/activate.err"

  log "Starting Plow stub for selftest: $root"
  PLOW_STUB_STATE_DIR="$stub_dir" bun run "$PLOW_STUB" >"$root/stub.out" 2>"$root/stub.err" &
  PIDS+=("$!")
  wait_for_file "$server_info" 15 || {
    err "stub did not write server-info"
    return 1
  }
  base_url="$(jq -r '.base_url' "$server_info")"
  mkdir -p "$home"

  auto_text_stub_code "$base_url" "$home/.claude/plow-chat/activation.json" "$root/seen-codes" &
  text_pid="$!"
  PIDS+=("$text_pid")

  set +e
  PLOW_CHAT_BASE_URL="$base_url" \
  DOMO_HOME="$home" \
  DOMO_ACTIVATION_TIMEOUT_SECONDS=20 \
  DOMO_ACTIVATION_POLL_INTERVAL_SECONDS=1 \
    "$SCRIPT_PATH" activate >"$out_file" 2>"$err_file"
  activate_rc=$?
  set -e
  kill "$text_pid" >/dev/null 2>&1 || true

  if [[ "$activate_rc" -ne 0 ]]; then
    err "stub activation failed with rc=$activate_rc"
    sed 's/^/[domo-activate] activate stderr: /' "$err_file" | tail -40
    return "$activate_rc"
  fi

  strict_state_file "$state_file" || {
    err "selftest state file failed strict validation"
    return 1
  }
  local mode
  mode="$(file_mode "$state_file")"
  [[ "$mode" == "600" ]] || {
    err "selftest state file mode is $mode, expected 600"
    return 1
  }

  curl -fsS "$base_url/_stub/calls" > "$calls_file"
  jq -e '
    .activate == 1
    and .redeem >= 1
    and .sequence[0].method == "POST"
    and .sequence[0].path == "/v1/auth/activate"
    and ([.sequence[].path] | index("/v1/auth/activate/redeem") != null)
  ' "$calls_file" >/dev/null || {
    err "selftest Plow call sequence failed strict validation"
    return 1
  }

  log "PASS selftest activated against stub"
  log "PASS state file shape and chmod-600: $state_file"
  log "PASS call sequence: $(jq -r '[.sequence[].path] | join(" -> ")' "$calls_file")"
  log "Selftest artifacts: $root"
}

usage() {
  cat <<USAGE
Usage: DOMO_HOME=/isolated/domo-home $SCRIPT_PATH <command>

Commands:
  activate [--force]  Request solo Plow activation, print code/number, poll redeem, write state
  harness             One-command real activation harness for the head chef
  status              Validate and print non-secret Plow activation state
  cleanup             Soft-delete the stored Plow chat and remove local state
  selftest            Start ref/installer/plow-stub.ts and verify activate->redeem->state

Environment:
  PLOW_CHAT_BASE_URL  Plow API base URL (default: https://api.plow.co)

If DOMO_HOME is omitted, a temp isolated home is created.
USAGE
}

case "${1:-harness}" in
  activate) shift; cmd_activate "$@" ;;
  harness) shift; cmd_harness "$@" ;;
  status) shift; cmd_status "$@" ;;
  cleanup) shift; cmd_cleanup "$@" ;;
  selftest) shift; cmd_selftest "$@" ;;
  -h|--help|help) usage ;;
  *) err "unknown command '${1:-}'"; usage >&2; exit 2 ;;
esac
