#!/usr/bin/env bash
set -euo pipefail

# Standalone Domo solo/group Plow activation piece.
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
INSTALL_STATE_FILE="$DOMO_HOME/install-state.json"
PLOW_DIR="$CONFIG_DIR/plow-chat"
PLOW_STATE_FILE="$PLOW_DIR/state.json"
PLOW_ACTIVATION_FILE="$PLOW_DIR/activation.json"
PLOW_BASE_URL="${PLOW_CHAT_BASE_URL:-https://api.plow.co}"
ACTIVATION_TIMEOUT_SECONDS="${DOMO_ACTIVATION_TIMEOUT_SECONDS:-300}"
ACTIVATION_POLL_INTERVAL_SECONDS="${DOMO_ACTIVATION_POLL_INTERVAL_SECONDS:-3}"
PLOW_STUB="$SCRIPT_DIR/installer/plow-stub.ts"

TMP_FILES=()
PIDS=()
GROUP_CODES_REVEALED=0

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

activation_message_for_code() {
  local display_code="$1"
  printf 'Plow Activate: %s' "$display_code"
}

strict_redeem_response() {
  jq -e '
    type == "object"
    and (
      .status == "pending"
      or (
        .status == "verified"
        and (.token | type == "string" and length > 0)
        and ((.chat == null) or (.chat.uid | type == "string" and startswith("cht_")))
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

plow_delete_chat() {
  local chat_uid="$1" token="$2"
  local url="${PLOW_BASE_URL%/}/v1/chats/$chat_uid" out err_file config="" code rc
  out="$(mktemp "${TMPDIR:-/tmp}/domo-plow-body.XXXXXX")"
  err_file="$(mktemp "${TMPDIR:-/tmp}/domo-plow-err.XXXXXX")"
  TMP_FILES+=("$out" "$err_file")

  config="$(umask 077; mktemp "${TMPDIR:-/tmp}/domo-plow-curl.XXXXXX")"
  TMP_FILES+=("$config")
  jq -rn --arg token "$token" '"header = \"Authorization: Bearer \($token)\"\n"' > "$config"
  chmod 600 "$config"

  set +e
  code="$(curl -sS -o "$out" -w "%{http_code}" -X DELETE "$url" -H 'Content-Type: application/json' --config "$config" 2>"$err_file")"
  rc=$?
  set -e

  if [[ "$rc" -ne 0 ]]; then
    local msg
    msg="$(tr '\n' ' ' < "$err_file" | sed 's/[[:space:]]\+/ /g')"
    err "Plow API DELETE /v1/chats/$chat_uid failed: ${msg:-curl exit $rc}"
    return "$rc"
  fi

  case "$code" in
    2??)
      log "Remote Plow chat deleted."
      ;;
    404|410)
      log "Remote Plow chat already absent (HTTP $code)."
      ;;
    *)
      local response
      response="$(tr '\n' ' ' < "$out" | sed 's/[[:space:]]\+/ /g')"
      err "Plow API DELETE /v1/chats/$chat_uid returned HTTP ${code:-000}: ${response:-<empty response>}"
      return 1
      ;;
  esac
}

write_activation_file() {
  local response="$1" tmp
  tmp="$(umask 077; mktemp "$PLOW_DIR/.activation.json.XXXXXX")"
  TMP_FILES+=("$tmp")
  printf '%s' "$response" | jq --arg base_url "${PLOW_BASE_URL%/}" '
    ("Plow Activate: " + .display_code) as $activation_message |
    {
      base_url: $base_url,
      activation_secret: .activation_secret,
      display_code: .display_code,
      activation_message: $activation_message,
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

write_install_mode() {
  local mode="$1"; shift
  mkdir -p "$DOMO_HOME"
  local tmp; tmp="$(umask 077; mktemp "$DOMO_HOME/.install-state.json.XXXXXX")"
  if [[ "$mode" == "group" ]]; then
    jq -n --argjson members "$(printf '%s\n' "$@" | jq -R . | jq -s '[.[] | select(length > 0)]')" '
      {interview:{mode:"group",status:"collected",members:$members}, activation:"pending"}
    ' > "$tmp"
  else
    jq -n '{interview:{mode:"solo",status:"collected",members:[]}, activation:"pending"}' > "$tmp"
  fi
  chmod 600 "$tmp"
  mv -f "$tmp" "$INSTALL_STATE_FILE"
}

activation_mode() {
  [[ -f "$INSTALL_STATE_FILE" ]] || { printf 'solo'; return 0; }
  jq -r '.interview.mode // "solo"' "$INSTALL_STATE_FILE" 2>/dev/null || printf 'solo'
}

group_members_json() {
  [[ -f "$INSTALL_STATE_FILE" ]] || { printf '[]'; return 0; }
  jq -c '[.interview.members[]? | strings | select(length > 0)]' "$INSTALL_STATE_FILE"
}

persist_solo_activation_detail() {
  local response="$1" tmp
  tmp="$(umask 077; mktemp "$DOMO_HOME/.install-state.json.XXXXXX")"
  jq --arg base_url "${PLOW_BASE_URL%/}" '
    . as $a |
    {
      interview:{mode:"solo",status:"collected",members:[]},
      activation:"complete",
      activation_detail:{
        mode:"solo",
        base_url:$base_url,
        status:"verified",
        activation_secret:$a.activation_secret,
        display_code:$a.display_code,
        activation_message:("Plow Activate: " + $a.display_code),
        send_to:$a.send_to,
        line_uid:($a.line_id // $a.line_uid // null)
      }
    }
  ' <<<"$response" > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$INSTALL_STATE_FILE"
}

persist_group_owner_activation_detail() {
  local response="$1" status="$2" tmp
  mkdir -p "$DOMO_HOME"
  tmp="$(umask 077; mktemp "$DOMO_HOME/.install-state.json.XXXXXX")"
  jq -n --arg base_url "${PLOW_BASE_URL%/}" --arg status "$status" --argjson owner "$response" --slurpfile prev_file "$INSTALL_STATE_FILE" '
    ($prev_file[0] // {}) as $prev |
    ($prev.interview // {mode:"group",status:"collected",members:[]}) as $interview |
    $prev + {
      interview:$interview,
      activation:"pending",
      activation_detail:(($prev.activation_detail // {}) + {
        mode:"group",
        base_url:$base_url,
        owner:{
          status:$status,
          activation_secret:$owner.activation_secret,
          display_code:$owner.display_code,
          activation_message:("Plow Activate: " + $owner.display_code),
          send_to:$owner.send_to,
          line_uid:($owner.line_id // $owner.line_uid // null)
        }
      })
    }
  ' > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$INSTALL_STATE_FILE"
}

plow_get_primary_line() {
  local token="$1"
  plow_http GET /v1/lines "" "$token" | jq -c '
    (.data // [])[0] as $line
    | if ($line.uid and $line.provider_key) then $line
      else error("GET /v1/lines returned no usable line") end
  '
}

group_chat_payload() {
  local line_id="$1" members_json="$2"
  jq -n --arg line_id "$line_id" --argjson members "$members_json" '
    {
      participants:
        ([{type:"agent", line_id:$line_id}]
         + ($members | map({type:"member", display_name:.})))
    }
  '
}

plow_create_group_chat() {
  local token="$1" line_id="$2" members_json="$3" payload
  payload="$(group_chat_payload "$line_id" "$members_json")"
  plow_http POST /v1/chats "$payload" "$token"
}

persist_group_activation_detail() {
  local token="$1" owner_json="$2" line_json="$3" chat_json="$4" tmp
  tmp="$(umask 077; mktemp "$DOMO_HOME/.install-state.json.XXXXXX")"
  jq -n \
    --arg base_url "${PLOW_BASE_URL%/}" \
    --arg token "$token" \
    --argjson owner "$owner_json" \
    --argjson line "$line_json" \
    --argjson chat "$chat_json" \
    --slurpfile prev "$INSTALL_STATE_FILE" '
    ($prev[0] // {}) as $state |
    ($chat.participants // [] | map(select(.type == "member") | {
      uid,
      display_name,
      status:(if .status == "active" then "verified" else "pending" end),
      verification_code,
      verification_code_expires_at,
      provider_key:($chat.provider_key // $line.provider_key)
    })) as $members |
    $state + {
      activation:"pending",
      activation_detail:{
        mode:"group",
        base_url:$base_url,
        owner:(($state.activation_detail.owner // {}) + {status:"verified"}),
        token:$token,
        line:$line,
        chat:$chat,
        participants:$members,
        chat_active:($chat.status == "active")
      }
    }
  ' > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$INSTALL_STATE_FILE"
}

group_detail_field() {
  local path="$1"
  jq -r ".activation_detail.$path // empty" "$INSTALL_STATE_FILE"
}

pending_group_members() {
  jq -r '[.activation_detail.participants[]? | select(.status != "verified") | .display_name] | join(", ")' "$INSTALL_STATE_FILE"
}

update_group_participant_status() {
  local uid="$1" provider_key="${2:-}" tmp
  tmp="$(umask 077; mktemp "$DOMO_HOME/.install-state.json.XXXXXX")"
  jq --arg uid "$uid" --arg provider_key "$provider_key" '
    .activation_detail.participants |= map(
      if .uid == $uid then . + {status:"verified"} + (if $provider_key != "" then {verified_provider_key:$provider_key} else {} end)
      else . end
    )
    | .activation_detail.chat.participants |= map(
      if .uid == $uid then . + {status:"active"} + (if $provider_key != "" then {provider_key:$provider_key} else {} end)
      else . end
    )
  ' "$INSTALL_STATE_FILE" > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$INSTALL_STATE_FILE"
}

set_group_chat_active() {
  local tmp; tmp="$(umask 077; mktemp "$DOMO_HOME/.install-state.json.XXXXXX")"
  jq '
    .activation = "complete"
    | .activation_detail.chat_active = true
    | .activation_detail.chat.status = "active"
    | .activation_detail.participants |= map(.status = "verified")
    | .activation_detail.chat.participants |= map(if .type == "member" then .status = "active" else . end)
  ' "$INSTALL_STATE_FILE" > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$INSTALL_STATE_FILE"
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

dashboard_activation_waiting() {
  local activation_message="$1" send_to="$2"
  INSTALLER_STATE_DIR="${INSTALLER_STATE_DIR:-}" "$SCRIPT_DIR/installer/client.sh" installer_step activate waiting "Text the activation message" >/dev/null 2>&1 || true
  INSTALLER_STATE_DIR="${INSTALLER_STATE_DIR:-}" "$SCRIPT_DIR/installer/client.sh" installer_verify "You" pending "$activation_message" "$send_to" self >/dev/null 2>&1 || true
}

dashboard_activation_verified() {
  INSTALLER_STATE_DIR="${INSTALLER_STATE_DIR:-}" "$SCRIPT_DIR/installer/client.sh" installer_verify "You" verified "" "" self >/dev/null 2>&1 || true
  INSTALLER_STATE_DIR="${INSTALLER_STATE_DIR:-}" "$SCRIPT_DIR/installer/client.sh" installer_step activate ok "Text line activated" >/dev/null 2>&1 || true
}

dashboard_group_owner_waiting() {
  local activation_message="$1" send_to="$2"
  INSTALLER_STATE_DIR="${INSTALLER_STATE_DIR:-}" "$SCRIPT_DIR/installer/client.sh" installer_step activate waiting "Text the owner activation message" >/dev/null 2>&1 || true
  INSTALLER_STATE_DIR="${INSTALLER_STATE_DIR:-}" "$SCRIPT_DIR/installer/client.sh" installer_verify "Owner" pending "$activation_message" "$send_to" self owner >/dev/null 2>&1 || true
}

dashboard_group_owner_verified() {
  INSTALLER_STATE_DIR="${INSTALLER_STATE_DIR:-}" "$SCRIPT_DIR/installer/client.sh" installer_verify "Owner" verified "" "" self owner >/dev/null 2>&1 || true
}

dashboard_group_members_from_detail() {
  local provider_key
  provider_key="$(group_detail_field 'line.provider_key')"
  INSTALLER_STATE_DIR="${INSTALLER_STATE_DIR:-}" "$SCRIPT_DIR/installer/client.sh" installer_step activate waiting "Verify household members" >/dev/null 2>&1 || true
  jq -r --arg fallback "$provider_key" '
    .activation_detail.participants[]?
    | [.display_name, .status, (.verification_code // ""), (.provider_key // $fallback), .uid]
    | @tsv
  ' "$INSTALL_STATE_FILE" | while IFS=$'\t' read -r name status code number uid; do
    INSTALLER_STATE_DIR="${INSTALLER_STATE_DIR:-}" "$SCRIPT_DIR/installer/client.sh" installer_verify "$name" "$status" "$code" "$number" false "$uid" >/dev/null 2>&1 || true
  done
}

dashboard_group_member_verified() {
  local uid="$1" name="$2"
  INSTALLER_STATE_DIR="${INSTALLER_STATE_DIR:-}" "$SCRIPT_DIR/installer/client.sh" installer_verify "${name:-Member}" verified "" "" false "$uid" >/dev/null 2>&1 || true
}

activation_detail_is_group_ready() {
  [[ -f "$INSTALL_STATE_FILE" ]] || return 1
  jq -e '.activation_detail.mode == "group" and (.activation_detail.token | type == "string") and (.activation_detail.chat.uid | startswith("cht_"))' "$INSTALL_STATE_FILE" >/dev/null
}

cmd_activate_solo() {
  log "DOMO_HOME=$DOMO_HOME"
  log "CLAUDE_CONFIG_DIR=$CONFIG_DIR"
  log "Requesting solo Plow activation at ${PLOW_BASE_URL%/} ..."

  local response activation_secret display_code activation_message send_to line_uid
  response="$(plow_http POST /v1/auth/activate '{"name":"Domo","provision_chat":true}')"
  if ! printf '%s' "$response" | strict_activation_response; then
    err "activation response failed strict validation"
    return 1
  fi

  activation_secret="$(printf '%s' "$response" | json_get '.activation_secret')"
  display_code="$(printf '%s' "$response" | json_get '.display_code')"
  activation_message="$(activation_message_for_code "$display_code")"
  send_to="$(printf '%s' "$response" | json_get '.send_to')"
  line_uid="$(printf '%s' "$response" | json_get '.line_id // .line_uid')"
  write_activation_file "$response"
  dashboard_activation_waiting "$activation_message" "$send_to"

  cat >&2 <<EOF

[domo-activate] ============================================================
[domo-activate] PLOW SOLO ACTIVATION - ACTION REQUIRED
[domo-activate] ============================================================
[domo-activate] From the phone you want bound to Domo, text EXACTLY:
[domo-activate]
[domo-activate]     $activation_message
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
  persist_solo_activation_detail "$response"

  if ! strict_state_file "$PLOW_STATE_FILE"; then
    err "written state file failed strict validation"
    return 1
  fi
  log "VERIFIED"
  dashboard_activation_verified
  log "State written to $PLOW_STATE_FILE (chmod $(file_mode "$PLOW_STATE_FILE")). chat_uid=$chat_uid"
  log "Token stored (NOT printed)."
}

plow_ws_ticket() {
  local token="$1" chat_uid="$2" payload
  payload="$(jq -n --arg chat_id "$chat_uid" '{chat_id:$chat_id}')"
  plow_http POST /v1/ws/ticket "$payload" "$token" | jq -r '.ticket // empty'
}

ws_url_for_ticket() {
  local ticket="$1" base="${PLOW_BASE_URL%/}" scheme rest
  case "$base" in
    https://*) scheme="wss"; rest="${base#https://}" ;;
    http://*) scheme="ws"; rest="${base#http://}" ;;
    *) err "cannot derive websocket URL from PLOW_BASE_URL=$PLOW_BASE_URL"; return 1 ;;
  esac
  printf '%s://%s/v1/ws?ticket=%s' "$scheme" "$rest" "$ticket"
}

plow_ws_listen_once() {
  local ws_url="$1"
  WS_URL="$ws_url" DOMO_WS_TIMEOUT_MS="${DOMO_WS_TIMEOUT_MS:-300000}" bun -e '
    const ws = new WebSocket(process.env.WS_URL);
    let sawActive = false;
    let opened = false;
    const timeout = setTimeout(() => {
      console.error("timed out waiting for Plow websocket frames");
      try { ws.close(); } catch {}
      process.exit(68);
    }, Number(process.env.DOMO_WS_TIMEOUT_MS || 300000));
    ws.addEventListener("open", () => { opened = true; });
    ws.addEventListener("message", (event) => {
      const text = String(event.data);
      console.log(text);
      try {
        if (JSON.parse(text).type === "chat_active") sawActive = true;
      } catch {}
      if (sawActive) ws.close();
    });
    ws.addEventListener("close", () => {
      clearTimeout(timeout);
      process.exit(sawActive ? 0 : opened ? 66 : 67);
    });
    ws.addEventListener("error", () => {
      clearTimeout(timeout);
      process.exit(67);
    });
  '
}

handle_group_ws_frame() {
  local frame="$1" type uid name provider pending
  type="$(printf '%s' "$frame" | jq -r '.type // empty')"
  case "$type" in
    connected)
      log "Plow websocket connected; waiting for member verification."
      if [[ "$GROUP_CODES_REVEALED" -eq 0 ]]; then
        dashboard_group_members_from_detail
        print_group_member_codes
        GROUP_CODES_REVEALED=1
      fi
      ;;
    participant_verified)
      uid="$(printf '%s' "$frame" | jq -r '.participant.uid // empty')"
      name="$(printf '%s' "$frame" | jq -r '.participant.display_name // empty')"
      provider="$(printf '%s' "$frame" | jq -r '.participant.provider_key // empty')"
      [[ -n "$uid" ]] || { err "participant_verified frame missing participant.uid"; return 1; }
      update_group_participant_status "$uid" "$provider"
      dashboard_group_member_verified "$uid" "$name"
      pending="$(pending_group_members)"
      log "Member verified: ${name:-$uid}. Pending: ${pending:-none}"
      ;;
    chat_active)
      set_group_chat_active
      dashboard_group_members_from_detail
      INSTALLER_STATE_DIR="${INSTALLER_STATE_DIR:-}" "$SCRIPT_DIR/installer/client.sh" installer_step activate ok "Group chat active" >/dev/null 2>&1 || true
      return 10
      ;;
    *)
      log "Ignoring Plow websocket frame type '${type:-unknown}'."
      ;;
  esac
}

listen_group_until_chat_active() {
  local token="$1" chat_uid="$2" reconnects=0
  while :; do
    local ticket ws_url fifo pid rc active=0 frame hrc
    ticket="$(plow_ws_ticket "$token" "$chat_uid")"
    [[ -n "$ticket" ]] || { err "POST /v1/ws/ticket returned no ticket"; return 1; }
    ws_url="$(ws_url_for_ticket "$ticket")"
    fifo="$(mktemp -u "${TMPDIR:-/tmp}/domo-ws.XXXXXX")"
    mkfifo "$fifo"
    plow_ws_listen_once "$ws_url" > "$fifo" &
    pid="$!"
    while IFS= read -r frame; do
      set +e
      handle_group_ws_frame "$frame"
      hrc=$?
      set -e
      [[ "$hrc" -eq 10 ]] && active=1
      [[ "$hrc" -eq 0 || "$hrc" -eq 10 ]] || { rm -f "$fifo"; return "$hrc"; }
    done < "$fifo"
    set +e
    wait "$pid"
    rc=$?
    set -e
    rm -f "$fifo"
    [[ "$active" -eq 1 ]] && return 0
    if [[ "$reconnects" -lt 1 ]]; then
      reconnects=$((reconnects + 1))
      log "Plow websocket dropped before chat_active; reconnecting once."
      sleep 1
    else
      err "Plow websocket dropped after one reconnect before chat_active"
      return "${rc:-1}"
    fi
  done
}

print_group_member_codes() {
  local provider_key
  provider_key="$(group_detail_field 'line.provider_key')"
  cat >&2 <<EOF

[domo-activate] ============================================================
[domo-activate] HOUSEHOLD MEMBER VERIFICATION - ACTION REQUIRED
[domo-activate] ============================================================
[domo-activate] Each household member now texts their own VERIFY code to: $provider_key
EOF
  jq -r '.activation_detail.participants[]? | "[domo-activate]   \(.display_name): \(.verification_code)"' "$INSTALL_STATE_FILE" >&2
  printf '[domo-activate] ============================================================\n' >&2
}

start_group_activation() {
  local members_json response activation_secret display_code activation_message send_to line_uid redeem token line_json line_id chat_json chat_uid
  members_json="$(group_members_json)"
  [[ "$(printf '%s' "$members_json" | jq 'length')" -gt 0 ]] || {
    err "group activation requires at least one member in $INSTALL_STATE_FILE"
    return 1
  }

  log "DOMO_HOME=$DOMO_HOME"
  log "CLAUDE_CONFIG_DIR=$CONFIG_DIR"
  log "Requesting group owner Plow activation at ${PLOW_BASE_URL%/} ..."

  response="$(plow_http POST /v1/auth/activate '{"name":"Domo"}')"
  if ! printf '%s' "$response" | strict_activation_response; then
    err "owner activation response failed strict validation"
    return 1
  fi

  activation_secret="$(printf '%s' "$response" | json_get '.activation_secret')"
  display_code="$(printf '%s' "$response" | json_get '.display_code')"
  activation_message="$(activation_message_for_code "$display_code")"
  send_to="$(printf '%s' "$response" | json_get '.send_to')"
  line_uid="$(printf '%s' "$response" | json_get '.line_id // .line_uid')"
  write_activation_file "$response"
  persist_group_owner_activation_detail "$response" pending
  dashboard_group_owner_waiting "$activation_message" "$send_to"

  cat >&2 <<EOF

[domo-activate] ============================================================
[domo-activate] PLOW GROUP OWNER ACTIVATION - ACTION REQUIRED
[domo-activate] ============================================================
[domo-activate] From the installer phone, text EXACTLY:
[domo-activate]
[domo-activate]     $activation_message
[domo-activate]
[domo-activate]   to:  $send_to
[domo-activate]
[domo-activate] (line: ${line_uid:-unknown}) Polling for owner verification up to ${ACTIVATION_TIMEOUT_SECONDS}s...
[domo-activate] ============================================================
EOF

  redeem="$(poll_activation_redeem "$activation_secret")"
  token="$(printf '%s' "$redeem" | json_get '.token')"
  [[ -n "$token" ]] || { err "verified owner redeem response had no token"; return 1; }
  persist_group_owner_activation_detail "$response" verified
  dashboard_group_owner_verified

  line_json="$(plow_get_primary_line "$token")"
  line_id="$(printf '%s' "$line_json" | jq -r '.uid')"
  chat_json="$(plow_create_group_chat "$token" "$line_id" "$members_json")"
  chat_uid="$(printf '%s' "$chat_json" | jq -r '.uid // empty')"
  [[ "$chat_uid" == cht_* ]] || { err "POST /v1/chats response missing chat uid"; return 1; }

  persist_group_activation_detail "$token" "$response" "$line_json" "$chat_json"
}

cmd_activate_group() {
  if activation_detail_is_group_ready; then
    log "Resuming group activation from $INSTALL_STATE_FILE"
  else
    start_group_activation
  fi

  local token chat_uid
  token="$(group_detail_field 'token')"
  chat_uid="$(group_detail_field 'chat.uid')"
  [[ -n "$token" && -n "$chat_uid" ]] || { err "activation_detail missing token/chat.uid"; return 1; }
  listen_group_until_chat_active "$token" "$chat_uid"
  write_state_file "$token" "$chat_uid"
  rm -f "$PLOW_ACTIVATION_FILE"
  strict_state_file "$PLOW_STATE_FILE" || { err "written state file failed strict validation"; return 1; }
  log "VERIFIED_GROUP"
  log "State written to $PLOW_STATE_FILE (chmod $(file_mode "$PLOW_STATE_FILE")). chat_uid=$chat_uid"
  log "Token stored (NOT printed)."
}

cmd_activate() {
  local force=0 explicit_mode="" members=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force=1; shift ;;
      --solo) explicit_mode="solo"; shift ;;
      --group) explicit_mode="group"; shift; members=("$@"); break ;;
      *) err "unknown activate argument '$1'"; return 2 ;;
    esac
  done

  require_tool curl
  require_tool jq
  require_tool bun
  setup_plow_dir

  if [[ -n "$explicit_mode" ]]; then
    if [[ "$explicit_mode" == "group" ]]; then
      [[ "${#members[@]}" -gt 0 ]] || { err "activate --group requires at least one member name"; return 2; }
      write_install_mode group "${members[@]}"
    else
      write_install_mode solo
    fi
  fi

  if [[ "$force" -eq 0 && -f "$PLOW_STATE_FILE" ]] && strict_state_file "$PLOW_STATE_FILE"; then
    log "already activated (state.json has a valid token). Use 'activate --force' to redo."
    return 0
  fi

  case "$(activation_mode)" in
    solo) cmd_activate_solo ;;
    group) cmd_activate_group ;;
    *) err "unknown activation mode in $INSTALL_STATE_FILE"; return 2 ;;
  esac
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
  plow_delete_chat "$chat_uid" "$token"
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
  local text
  trap 'exit 0' TERM INT
  while :; do
    if [[ -f "$activation_file" ]]; then
      text="$(jq -r '.activation_message // empty' "$activation_file" 2>/dev/null || true)"
      if [[ -n "$text" ]] && ! grep -qxF "$text" "$seen_file" 2>/dev/null; then
        printf '%s\n' "$text" >> "$seen_file"
        jq -n --arg text "$text" '{text: $text}' \
          | curl -fsS -X POST "$base_url/_stub/text" -H 'Content-Type: application/json' -d @- >/dev/null
        return 0
      fi
    fi
    sleep 0.2
  done
}

auto_text_group_stub_codes() {
  local base_url="$1" state_file="$2" seen_file="$3"
  local codes ws_connect
  trap 'exit 0' TERM INT
  while :; do
    if [[ -f "$state_file" ]]; then
      ws_connect="$(curl -fsS "$base_url/_stub/calls" 2>/dev/null | jq -r '.ws_connect // 0' 2>/dev/null || printf '0')"
      if [[ "$ws_connect" -gt 0 ]]; then
        codes="$(jq -r '.activation_detail.participants[]? | select(.status != "verified") | .verification_code // empty' "$state_file" 2>/dev/null || true)"
      else
        codes=""
      fi
      if [[ -n "$codes" ]]; then
        while IFS= read -r code; do
          [[ -n "$code" ]] || continue
          if ! grep -qxF "$code" "$seen_file" 2>/dev/null; then
            printf '%s\n' "$code" >> "$seen_file"
            jq -n --arg text "$code" '{text: $text}' \
              | curl -fsS -X POST "$base_url/_stub/text" -H 'Content-Type: application/json' -d @- >/dev/null
          fi
        done <<< "$codes"
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
  local activation_message display_code bare_code_rc
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

  activation_message="$(sed -n '1p' "$root/seen-codes" 2>/dev/null || true)"
  [[ "$activation_message" == Plow\ Activate:\ * ]] || {
    err "selftest did not send full activation message; got '${activation_message:-<empty>}'"
    return 1
  }
  grep -F "$activation_message" "$err_file" >/dev/null || {
    err "activation stderr did not display the full activation message"
    return 1
  }
  display_code="${activation_message#Plow Activate: }"
  set +e
  jq -n --arg text "$display_code" '{text: $text}' \
    | curl -fsS -X POST "$base_url/_stub/text" -H 'Content-Type: application/json' -d @- >/dev/null 2>&1
  bare_code_rc=$?
  set -e
  [[ "$bare_code_rc" -ne 0 ]] || {
    err "stub accepted bare activation code; expected full activation message only"
    return 1
  }

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
  log "PASS full activation message required: $activation_message"
  log "PASS state file shape and chmod-600: $state_file"
  log "PASS call sequence: $(jq -r '[.sequence[].path] | join(" -> ")' "$calls_file")"
  log "Selftest artifacts: $root"
}

cmd_group_selftest() {
  require_tool bun
  require_tool curl
  require_tool jq
  [[ -f "$PLOW_STUB" ]] || {
    err "stub not found at $PLOW_STUB"
    return 1
  }

  local root stub_dir home server_info base_url state_file install_state calls_file text_pid member_pid activate_rc chat_uid
  root="$(mktemp -d "${TMPDIR:-/tmp}/domo-activate-group-selftest.XXXXXX")"
  stub_dir="$root/stub"
  home="$root/home"
  server_info="$stub_dir/server-info"
  state_file="$home/.claude/plow-chat/state.json"
  install_state="$home/install-state.json"
  calls_file="$root/calls.json"

  log "Starting Plow stub for group selftest: $root"
  PLOW_STUB_STATE_DIR="$stub_dir" bun run "$PLOW_STUB" >"$root/stub.out" 2>"$root/stub.err" &
  PIDS+=("$!")
  wait_for_file "$server_info" 15 || {
    err "stub did not write server-info"
    return 1
  }
  base_url="$(jq -r '.base_url' "$server_info")"
  mkdir -p "$home"

  auto_text_stub_code "$base_url" "$home/.claude/plow-chat/activation.json" "$root/seen-owner-codes" &
  text_pid="$!"
  PIDS+=("$text_pid")
  auto_text_group_stub_codes "$base_url" "$install_state" "$root/seen-member-codes" &
  member_pid="$!"
  PIDS+=("$member_pid")

  set +e
  PLOW_CHAT_BASE_URL="$base_url" \
  DOMO_HOME="$home" \
  DOMO_ACTIVATION_TIMEOUT_SECONDS=20 \
  DOMO_ACTIVATION_POLL_INTERVAL_SECONDS=1 \
  DOMO_WS_TIMEOUT_MS=20000 \
    "$SCRIPT_PATH" activate --group "You" "Pat" >"$root/group.out" 2>"$root/group.err"
  activate_rc=$?
  set -e
  kill "$text_pid" "$member_pid" >/dev/null 2>&1 || true

  if [[ "$activate_rc" -ne 0 ]]; then
    err "stub group activation failed with rc=$activate_rc"
    sed 's/^/[domo-activate] group stderr: /' "$root/group.err" | tail -80
    return "$activate_rc"
  fi

  strict_state_file "$state_file" || {
    err "group selftest state file failed strict validation"
    return 1
  }
  chat_uid="$(jq -r '.chat_uid' "$state_file")"
  jq -e '
    .interview.mode == "group"
    and .activation == "complete"
    and .activation_detail.mode == "group"
    and .activation_detail.chat_active == true
    and ((.activation_detail.participants // []) | length == 2)
    and all(.activation_detail.participants[]; .status == "verified")
  ' "$install_state" >/dev/null || {
    err "group selftest install-state did not record verified group activation"
    jq . "$install_state" >&2 || true
    return 1
  }
  curl -fsS "$base_url/_stub/calls" > "$calls_file"
  jq -e --arg chat_uid "$chat_uid" '
    .activate == 1
    and .redeem >= 1
    and .lines == 1
    and .chats == 1
    and .ws_ticket >= 1
    and .ws_connect >= 1
    and ([.sequence[].path] | index("/v1/chats") != null)
    and ([.sequence[].path] | index("/v1/ws") != null)
  ' "$calls_file" >/dev/null || {
    err "group selftest Plow call sequence failed strict validation"
    jq . "$calls_file" >&2 || true
    return 1
  }

  log "PASS group selftest activated against stub"
  log "PASS group participants verified: $(jq -r '[.activation_detail.participants[].display_name] | join(", ")' "$install_state")"
  log "PASS group state shape and chmod-600: $state_file (chat_uid=$chat_uid)"
  log "PASS group call sequence: $(jq -r '[.sequence[].path] | join(" -> ")' "$calls_file")"
  log "Selftest artifacts: $root"
}

usage() {
  cat <<USAGE
Usage: DOMO_HOME=/isolated/domo-home $SCRIPT_PATH <command>

Commands:
  activate [--force] [--solo|--group NAME...]
                      Request solo or group Plow activation, print text actions,
                      poll verification, write state
  harness             One-command real activation harness for the head chef
  status              Validate and print non-secret Plow activation state
  cleanup             Soft-delete the stored Plow chat and remove local state
  selftest            Start ref/installer/plow-stub.ts and verify activate->redeem->state
  group-selftest      Verify group owner activation, chat create, member VERIFY, WSS active

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
  group-selftest) shift; cmd_group_selftest "$@" ;;
  -h|--help|help) usage ;;
  *) err "unknown command '${1:-}'"; usage >&2; exit 2 ;;
esac
