#!/usr/bin/env bash
set -euo pipefail

# Standalone Domo ready piece.
# Given a logged-in DOMO_HOME and Piece-3 Plow state, authors the default Domo
# config, starts the background daemon, and sends a deterministic ready text.

unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

if [[ -z "${DOMO_HOME:-}" ]]; then
  DOMO_HOME="$(mktemp -d "${TMPDIR:-/tmp}/domo-ready-piece.XXXXXX")"
  CREATED_TEMP_HOME=1
else
  CREATED_TEMP_HOME=0
fi

CONFIG_DIR="$DOMO_HOME/.claude"
INSTALL_STATE_FILE="$DOMO_HOME/install-state.json"
WORKSPACE="$DOMO_HOME/workspace"
RUN_DIR="$CONFIG_DIR/run"
PLOW_DIR="$CONFIG_DIR/plow-chat"
PLOW_STATE_FILE="$PLOW_DIR/state.json"
PLOW_CONNECTED_MARKER="$PLOW_DIR/connected"
META_FILE="$CONFIG_DIR/domo.json"
READY_CONFIG_FILE="$CONFIG_DIR/domo-ready.json"
LOG_FILE="$RUN_DIR/domo-ready.log"
PID_FILE="$RUN_DIR/domo-ready.pid"
SIG_FILE="$RUN_DIR/domo-ready.sig"
TMUX_SESSION_FILE="$RUN_DIR/domo-ready.tmux"
PLOW_CHANNEL_DIR="$SCRIPT_DIR/channels/plow-chat"
SPAWN_CONFIRM="$SCRIPT_DIR/bin/spawn-confirm.expect"
ACTIVATE_PIECE="$SCRIPT_DIR/domo-activate-piece.sh"
PLOW_STUB="$SCRIPT_DIR/installer/plow-stub.ts"
READY_TEXT="${DOMO_READY_TEXT:-Domo is ready. Text me here when you need help with the household or calendar.}"
READY_TIMEOUT_SECONDS="${DOMO_READY_TIMEOUT_SECONDS:-60}"
PERMISSION_MODE="${DOMO_PERMISSION_MODE:-auto}"

PIDS=()
TMP_FILES=()

log() { printf '[domo-ready] %s\n' "$*"; }
err() { printf '[domo-ready] ERROR: %s\n' "$*" >&2; }
warn() { printf '[domo-ready] WARNING: %s\n' "$*" >&2; }

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

set_domo_home() {
  DOMO_HOME="$1"
  CONFIG_DIR="$DOMO_HOME/.claude"
  INSTALL_STATE_FILE="$DOMO_HOME/install-state.json"
  WORKSPACE="$DOMO_HOME/workspace"
  RUN_DIR="$CONFIG_DIR/run"
  PLOW_DIR="$CONFIG_DIR/plow-chat"
  PLOW_STATE_FILE="$PLOW_DIR/state.json"
  PLOW_CONNECTED_MARKER="$PLOW_DIR/connected"
  META_FILE="$CONFIG_DIR/domo.json"
  READY_CONFIG_FILE="$CONFIG_DIR/domo-ready.json"
  LOG_FILE="$RUN_DIR/domo-ready.log"
  PID_FILE="$RUN_DIR/domo-ready.pid"
  SIG_FILE="$RUN_DIR/domo-ready.sig"
  TMUX_SESSION_FILE="$RUN_DIR/domo-ready.tmux"
}

file_mode() {
  local path="$1"
  stat -f '%Lp' "$path" 2>/dev/null || stat -c '%a' "$path" 2>/dev/null || printf 'unknown'
}

workspace_slug() {
  printf '%s' "$WORKSPACE" | sed 's/[\/.]/-/g'
}

projects_dir() {
  printf '%s/projects/%s' "$CONFIG_DIR" "$(workspace_slug)"
}

ensure_workspace_trusted() {
  require_tool jq
  mkdir -p "$CONFIG_DIR"

  local config_file="$CONFIG_DIR/.claude.json" tmp
  tmp="$(umask 077; mktemp "$CONFIG_DIR/.claude.json.XXXXXX")"
  if [[ -f "$config_file" ]]; then
    jq --arg workspace "$WORKSPACE" '
      .projects = (.projects // {})
      | .projects[$workspace] = ((.projects[$workspace] // {}) + {hasTrustDialogAccepted: true})
    ' "$config_file" > "$tmp"
  else
    jq -n --arg workspace "$WORKSPACE" '
      {
        projects: {
          ($workspace): {
            hasTrustDialogAccepted: true
          }
        }
      }
    ' > "$tmp"
  fi
  chmod 600 "$tmp"
  mv -f "$tmp" "$config_file"
  log "Trusted workspace for daemon launch: $WORKSPACE"
}

auth_env() {
  env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR="$CONFIG_DIR" "$@"
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

auth_confirmed() {
  local out
  out="$(auth_env claude auth status --json 2>/dev/null || true)"
  printf '%s' "$out" | jq -e '
    type == "object"
    and .loggedIn == true
    and .authMethod == "claude.ai"
    and .apiProvider == "firstParty"
  ' >/dev/null
}

read_session_id() {
  [[ -f "$META_FILE" ]] || { printf ''; return 0; }
  jq -r '.session_id // empty' "$META_FILE" 2>/dev/null || printf ''
}

write_meta() {
  local sid="$1" tmp
  tmp="$(umask 077; mktemp "$CONFIG_DIR/.domo.json.XXXXXX")"
  jq -n --arg sid "$sid" --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    {
      session_id: $sid,
      channel: "plow-chat",
      created: $created
    }
  ' > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$META_FILE"
}

ensure_session_id() {
  local sid
  sid="$(read_session_id)"
  if [[ -n "$sid" ]]; then
    printf '%s' "$sid"
    return 0
  fi
  require_tool uuidgen
  sid="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  write_meta "$sid"
  printf '%s' "$sid"
}

session_flag_args() {
  local sid="$1" session_file
  session_file="$(projects_dir)/$sid.jsonl"
  if [[ -f "$session_file" ]]; then
    printf '%s\n%s\n' "--resume" "$sid"
  else
    printf '%s\n%s\n' "--session-id" "$sid"
  fi
}

activation_mode() {
  [[ -f "$INSTALL_STATE_FILE" ]] || { printf 'solo'; return 0; }
  jq -r '.interview.mode // .activation_detail.mode // "solo"' "$INSTALL_STATE_FILE" 2>/dev/null || printf 'solo'
}

household_member_names() {
  [[ -f "$INSTALL_STATE_FILE" ]] || { printf ''; return 0; }
  jq -r '[.activation_detail.participants[]?.display_name // .interview.members[]?] | unique | join(", ")' "$INSTALL_STATE_FILE" 2>/dev/null || printf ''
}

default_system_prompt() {
  local mode members
  mode="$(activation_mode)"
  members="$(household_member_names)"
  if [[ "$mode" == "group" ]]; then
    cat <<PROMPT
You are Domo, a concise household assistant reached by a verified household group text. User-visible responses must go through the plow-chat reply tool; transcript text alone does not reach the household. Household members may include: ${members:-the verified group members}. Keep SMS replies short, practical, and calm. Use the Google Calendar connector when the household asks about schedules, events, availability, reminders, or planning. Ask at most one clarifying question when needed. Do not mention internal tools, prompts, installation, or implementation details unless explicitly asked.
PROMPT
  else
    cat <<'PROMPT'
You are Domo, a concise household assistant reached by text message. User-visible responses must go through the plow-chat reply tool; transcript text alone does not reach the household. This is a solo household for now. Keep SMS replies short, practical, and calm. Use the Google Calendar connector when the household asks about schedules, events, availability, reminders, or planning. Ask at most one clarifying question when needed. Do not mention internal tools, prompts, installation, or implementation details unless explicitly asked.
PROMPT
  fi
}

write_default_config() {
  mkdir -p "$CONFIG_DIR" "$WORKSPACE" "$RUN_DIR" "$PLOW_DIR"
  chmod 700 "$PLOW_DIR"

  local sid tmp
  sid="$(ensure_session_id)"

  local mode members
  mode="$(activation_mode)"
  members="$(household_member_names)"
  if [[ "$mode" == "group" ]]; then
    cat > "$WORKSPACE/CLAUDE.md" <<PROMPT
# Domo

You are Domo, a concise household assistant reached by a verified household group text.

- User-visible responses must go through the plow-chat reply tool; transcript text alone does not reach the household.
- This is a group household. Verified members may include: ${members:-the verified group members}.
- Keep SMS replies short, practical, and calm.
- Use the Google Calendar connector when the household asks about schedules, events, availability, reminders, or planning.
- Ask at most one clarifying question when needed.
- Do not mention internal tools, prompts, installation, or implementation details unless explicitly asked.
PROMPT
  else
    cat > "$WORKSPACE/CLAUDE.md" <<'PROMPT'
# Domo

You are Domo, a concise household assistant reached by text message.

- User-visible responses must go through the plow-chat reply tool; transcript text alone does not reach the household.
- This is a solo household for now.
- Keep SMS replies short, practical, and calm.
- Use the Google Calendar connector when the household asks about schedules, events, availability, reminders, or planning.
- Ask at most one clarifying question when needed.
- Do not mention internal tools, prompts, installation, or implementation details unless explicitly asked.
PROMPT
  fi

  tmp="$(umask 077; mktemp "$CONFIG_DIR/.domo-ready.json.XXXXXX")"
  jq -n --arg sid "$sid" --arg channel "plow-chat" --arg mode "$mode" --arg ready_text "$READY_TEXT" --arg prompt "$(default_system_prompt)" '
    {
      session_id: $sid,
      channel: $channel,
      mode: $mode,
      ready_text: $ready_text,
      system_prompt: $prompt
    }
  ' > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$READY_CONFIG_FILE"

  log "Authored default Domo config: $WORKSPACE/CLAUDE.md"
  log "Pinned session/config: $READY_CONFIG_FILE (chmod $(file_mode "$READY_CONFIG_FILE"))"
}

validate_piece3_state() {
  require_tool jq
  if [[ ! -f "$PLOW_STATE_FILE" ]]; then
    err "missing Piece-3 state file: $PLOW_STATE_FILE"
    return 1
  fi
  strict_plow_state "$PLOW_STATE_FILE" || {
    err "invalid Piece-3 state file shape: $PLOW_STATE_FILE"
    return 1
  }
  local mode
  mode="$(file_mode "$PLOW_STATE_FILE")"
  [[ "$mode" == "600" ]] || {
    err "state file mode is $mode, expected 600"
    return 1
  }
}

register_channel() {
  require_tool claude
  require_tool bun
  [[ -f "$PLOW_CHANNEL_DIR/server.ts" ]] || {
    err "missing plow-chat channel server: $PLOW_CHANNEL_DIR/server.ts"
    return 1
  }
  auth_env claude mcp remove plow-chat </dev/null >/dev/null 2>&1 || true
  auth_env claude mcp add plow-chat --scope user -- \
    bun run --cwd "$PLOW_CHANNEL_DIR" --shell=bun --silent start </dev/null >/dev/null
  log "Registered MCP server 'plow-chat' in isolated Claude config."
}

daemon_kill_pattern() {
  local sid
  sid="$(read_session_id)"
  if [[ -n "$sid" ]]; then printf '%s' "$sid"; else printf '%s' "server:plow-chat"; fi
}

write_daemon_sig() {
  local tmp
  tmp="$(umask 077; mktemp "$RUN_DIR/.domo-ready.sig.XXXXXX")"
  printf '%s\n' "$(daemon_kill_pattern)" > "$tmp"
  mv -f "$tmp" "$SIG_FILE"
}

tmux_session_name() {
  local sid compact
  sid="$(read_session_id)"
  compact="$(printf '%s' "${sid:-plow-chat}" | tr -cd '[:alnum:]')"
  printf 'domo-ready-%s' "${compact:-plowchat}"
}

write_tmux_launch_script() {
  local script="$RUN_DIR/domo-ready-launch.sh" arg
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'cd %q\n' "$WORKSPACE"
    printf 'export PLOW_CHAT_STATE=%q\n' "$PLOW_STATE_FILE"
    printf 'export PLOW_CHAT_CONNECTED_MARKER=%q\n' "$PLOW_CONNECTED_MARKER"
    printf 'export CLAUDE_CONFIG_DIR=%q\n' "$CONFIG_DIR"
    if command -v expect >/dev/null 2>&1 && [[ -f "$SPAWN_CONFIRM" ]]; then
      printf 'exec expect -f %q' "$SPAWN_CONFIRM"
      for arg in "${argv[@]}"; do printf ' %q' "$arg"; done
      printf ' >>%q 2>&1\n' "$LOG_FILE"
    else
      printf 'exec'
      for arg in "${argv[@]}"; do printf ' %q' "$arg"; done
      printf ' >>%q 2>&1\n' "$LOG_FILE"
    fi
  } > "$script"
  chmod 700 "$script"
  printf '%s' "$script"
}

wait_for_log() {
  local pattern="$1" timeout="$2" label="$3"
  local deadline=$(( $(date +%s) + timeout ))
  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    if [[ -f "$LOG_FILE" ]] && grep -qiE "$pattern" "$LOG_FILE"; then
      return 0
    fi
    sleep 1
  done
  warn "timed out waiting for $label in $LOG_FILE"
  return 1
}

clear_plow_connected_marker() {
  rm -f "$PLOW_CONNECTED_MARKER"
}

wait_for_plow_connected_marker() {
  local timeout="$1" marker_pid marker_chat expected_chat
  local deadline=$(( $(date +%s) + timeout ))
  expected_chat="$(jq -r '.chat_uid' "$PLOW_STATE_FILE" 2>/dev/null || true)"
  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    if [[ -f "$PLOW_CONNECTED_MARKER" ]]; then
      if jq -e --arg chat "$expected_chat" '
        type == "object"
        and .connected == true
        and (.chat_uid // "") == $chat
        and (.pid | type == "number")
      ' "$PLOW_CONNECTED_MARKER" >/dev/null 2>&1; then
        marker_pid="$(jq -r '.pid' "$PLOW_CONNECTED_MARKER")"
        marker_chat="$(jq -r '.chat_uid' "$PLOW_CONNECTED_MARKER")"
        if [[ -n "$marker_pid" ]] && kill -0 "$marker_pid" 2>/dev/null; then
          log "plow-chat connected marker present (pid $marker_pid, chat_uid $marker_chat)."
          return 0
        fi
      fi
    fi
    sleep 0.2
  done
  warn "timed out waiting for plow-chat connected marker: $PLOW_CONNECTED_MARKER"
  return 1
}

cmd_stop() {
  local pid=""
  if [[ -f "$PID_FILE" ]]; then
    pid="$(tr -d '[:space:]' < "$PID_FILE" 2>/dev/null || true)"
  fi

  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    log "Stopping daemon pid=$pid"
    kill -TERM "$pid" 2>/dev/null || true
    local i=0
    while kill -0 "$pid" 2>/dev/null && [[ "$i" -lt 10 ]]; do
      sleep 0.5
      i=$((i + 1))
    done
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
  fi

  local sig=""
  if [[ -f "$SIG_FILE" ]]; then
    sig="$(tr -d '\n' < "$SIG_FILE" 2>/dev/null || true)"
  fi
  [[ -n "$sig" ]] || sig="$(daemon_kill_pattern)"
  if [[ -n "$sig" ]] && pgrep -f -- "$sig" >/dev/null 2>&1; then
    pkill -TERM -f -- "$sig" 2>/dev/null || true
  fi

  if pgrep -f "$PLOW_CHANNEL_DIR" >/dev/null 2>&1; then
    pkill -f "$PLOW_CHANNEL_DIR" 2>/dev/null || true
  fi

  local tmux_session=""
  if [[ -f "$TMUX_SESSION_FILE" ]]; then
    tmux_session="$(tr -d '\n' < "$TMUX_SESSION_FILE" 2>/dev/null || true)"
  fi
  [[ -n "$tmux_session" ]] || tmux_session="$(tmux_session_name)"
  if command -v tmux >/dev/null 2>&1 && tmux has-session -t "$tmux_session" 2>/dev/null; then
    log "Stopping tmux daemon session: $tmux_session"
    tmux kill-session -t "$tmux_session" 2>/dev/null || true
  fi

  rm -f "$PID_FILE" "$SIG_FILE" "$TMUX_SESSION_FILE"
  clear_plow_connected_marker
  log "Daemon stopped."
}

cmd_start() {
  require_tool claude
  require_tool jq
  require_tool bun
  validate_piece3_state
  auth_confirmed || {
    err "Claude login is not confirmed for isolated config: $CONFIG_DIR"
    err "Run Piece 1 login for this DOMO_HOME first."
    return 2
  }
  write_default_config
  cmd_stop
  ensure_workspace_trusted
  register_channel

  local oldpid=""
  if [[ -f "$PID_FILE" ]]; then
    oldpid="$(tr -d '[:space:]' < "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "$oldpid" ]] && kill -0 "$oldpid" 2>/dev/null; then
      log "daemon already running (pid $oldpid)"
      return 0
    fi
    rm -f "$PID_FILE"
  fi

  mkdir -p "$RUN_DIR" "$WORKSPACE"
  local sid prompt
  sid="$(ensure_session_id)"
  prompt="$(default_system_prompt)"

  export PLOW_CHAT_STATE="$PLOW_STATE_FILE"
  export PLOW_CHAT_CONNECTED_MARKER="$PLOW_CONNECTED_MARKER"
  export CLAUDE_CONFIG_DIR="$CONFIG_DIR"

  local argv=(
    claude
    --dangerously-load-development-channels server:plow-chat
    --permission-mode "$PERMISSION_MODE"
    --append-system-prompt "$prompt"
  )
  if [[ -f "$(projects_dir)/$sid.jsonl" ]]; then
    argv+=(--resume "$sid")
  else
    argv+=(--session-id "$sid")
  fi

  {
    printf '\n===== domo-ready start %s =====\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'channel=plow-chat permission=%s session=%s workspace=%s\n' "$PERMISSION_MODE" "$sid" "$WORKSPACE"
  } >>"$LOG_FILE" 2>&1

  local launched_pid
  if command -v tmux >/dev/null 2>&1; then
    local tmux_session launch_script
    tmux_session="$(tmux_session_name)"
    launch_script="$(write_tmux_launch_script)"
    tmux has-session -t "$tmux_session" 2>/dev/null && tmux kill-session -t "$tmux_session" 2>/dev/null || true
    tmux new-session -d -s "$tmux_session" -c "$WORKSPACE" "exec bash $(quote "$launch_script")"
    printf '%s\n' "$tmux_session" > "$TMUX_SESSION_FILE"
    launched_pid="$(tmux display-message -p -t "$tmux_session" '#{pane_pid}' 2>/dev/null || true)"
    [[ -n "$launched_pid" ]] || launched_pid="$(pgrep -f "$tmux_session" | head -1 || true)"
  else
    local oldpwd
    oldpwd="$(pwd)"
    cd "$WORKSPACE"
    if command -v expect >/dev/null 2>&1 && [[ -f "$SPAWN_CONFIRM" ]]; then
      nohup expect -f "$SPAWN_CONFIRM" "${argv[@]}" </dev/null >>"$LOG_FILE" 2>&1 &
    else
      warn "expect not found; daemon may hang at development-channel confirmation."
      nohup "${argv[@]}" </dev/null >>"$LOG_FILE" 2>&1 &
    fi
    launched_pid="$!"
    disown %% 2>/dev/null || true
    cd "$oldpwd"
  fi
  printf '%s\n' "$launched_pid" > "$PID_FILE"

  write_daemon_sig
  local pid
  pid="$(tr -d '[:space:]' < "$PID_FILE")"
  sleep 1
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$PID_FILE" "$SIG_FILE"
    err "daemon exited immediately; see $LOG_FILE"
    tail -20 "$LOG_FILE" 2>/dev/null | sed 's/^/[domo-ready] log: /' || true
    return 1
  fi

  log "Daemon process up (pid $pid)."
  wait_for_plow_connected_marker "$READY_TIMEOUT_SECONDS" || return 1
  log "Channel connected according to plow-chat marker."
}

send_ready_via_channel_tool() {
  local state_file="$1" ready_text="$2" base_url="${3:-}" chat_uid="${4:-}" out_file="${5:-}"
  require_tool bun
  require_tool jq
  [[ -n "$out_file" ]] || out_file="$(mktemp "${TMPDIR:-/tmp}/domo-ready-mcp.XXXXXX")"

  CHANNEL_DIR="$PLOW_CHANNEL_DIR" \
  PLOW_CHAT_STATE="$state_file" \
  DOMO_READY_TEXT="$ready_text" \
  PLOW_STUB_BASE_URL="$base_url" \
  PLOW_STUB_CHAT_UID="$chat_uid" \
  bun -e '
    import { pathToFileURL } from "node:url";

    const channelDir = process.env.CHANNEL_DIR;
    const sdkBase = `${channelDir}/node_modules/@modelcontextprotocol/sdk/dist/esm`;
    const { Client } = await import(pathToFileURL(`${sdkBase}/client/index.js`).href);
    const { StdioClientTransport } = await import(pathToFileURL(`${sdkBase}/client/stdio.js`).href);

    const readyText = process.env.DOMO_READY_TEXT;
    const baseUrl = process.env.PLOW_STUB_BASE_URL || "";
    const chatUid = process.env.PLOW_STUB_CHAT_UID || "";

    function fail(message) {
      console.error(message);
      process.exit(1);
    }
    async function sleep(ms) {
      await new Promise((resolve) => setTimeout(resolve, ms));
    }
    async function jsonFetch(url, options = {}) {
      const res = await fetch(url, options);
      if (!res.ok) fail(`${options.method || "GET"} ${url} -> HTTP ${res.status}: ${await res.text()}`);
      return await res.json();
    }
    async function waitFor(predicate, label, timeoutMs = 15000) {
      const deadline = Date.now() + timeoutMs;
      while (Date.now() < deadline) {
        const value = await predicate();
        if (value) return value;
        await sleep(150);
      }
      fail(`timed out waiting for ${label}`);
    }

    const before = baseUrl ? Number((await jsonFetch(`${baseUrl}/_stub/calls`)).ws_connect || 0) : 0;
    const client = new Client({ name: "domo-ready-host", version: "1.0.0" }, { capabilities: {} });
    const transport = new StdioClientTransport({
      command: "bun",
      args: ["server.ts"],
      cwd: channelDir,
      env: {
        PATH: process.env.PATH,
        HOME: process.env.HOME,
        PLOW_CHAT_STATE: process.env.PLOW_CHAT_STATE,
        PLOW_CHAT_CONNECTED_MARKER: "",
      },
      stderr: "pipe",
    });
    const stderr = [];
    transport.stderr?.on("data", (chunk) => stderr.push(String(chunk)));

    try {
      await client.connect(transport);
      if (baseUrl) {
        await waitFor(async () => {
          const calls = await jsonFetch(`${baseUrl}/_stub/calls`);
          return Number(calls.ws_connect || 0) > before;
        }, "plow-chat websocket connection");
      }

      const result = await client.callTool({ name: "reply", arguments: { text: readyText } });
      if (result.isError) fail(`reply tool returned error: ${JSON.stringify(result)}`);

      let recorded = false;
      let calls = {};
      if (baseUrl && chatUid) {
        await waitFor(async () => {
          const body = await jsonFetch(`${baseUrl}/_stub/messages?chat_uid=${encodeURIComponent(chatUid)}`);
          return (body.data || []).some((m) => m.direction === "outbound" && m.body === readyText);
        }, "ready outbound message");
        calls = await jsonFetch(`${baseUrl}/_stub/calls`);
        recorded = true;
      }

      console.log(JSON.stringify({
        status: "sent",
        ready_text: readyText,
        recorded,
        ws_connect: calls.ws_connect ?? null,
        outbound_messages: calls.outbound_messages ?? null,
      }));
    } finally {
      await client.close().catch(() => {});
      if (stderr.length && !baseUrl) console.error(stderr.join(""));
    }
  ' > "$out_file"
  cat "$out_file"
}

cmd_ready() {
  cmd_start
  local out
  out="$(send_ready_via_channel_tool "$PLOW_STATE_FILE" "$READY_TEXT")"
  printf '%s\n' "$out" > "$RUN_DIR/ready-send.json"
  chmod 600 "$RUN_DIR/ready-send.json"
  log "READY_TEXT_SENT via plow-chat reply tool. Details: $RUN_DIR/ready-send.json"
}

cmd_status() {
  require_tool jq
  local ok=0
  log "DOMO_HOME=$DOMO_HOME"
  log "CLAUDE_CONFIG_DIR=$CONFIG_DIR"
  if auth_confirmed; then log "auth=confirmed"; else log "auth=not_confirmed"; ok=1; fi
  if [[ -f "$PLOW_STATE_FILE" ]] && strict_plow_state "$PLOW_STATE_FILE"; then
    log "plow_state=present chat_uid=$(jq -r '.chat_uid' "$PLOW_STATE_FILE") mode=$(file_mode "$PLOW_STATE_FILE")"
  else
    log "plow_state=missing_or_invalid"; ok=1
  fi
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid="$(tr -d '[:space:]' < "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then log "daemon=alive pid=$pid"; else log "daemon=dead"; ok=1; fi
  else
    log "daemon=not_running"; ok=1
  fi
  [[ "$ok" -eq 0 ]]
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
  while :; do
    if [[ -f "$activation_file" ]]; then
      text="$(jq -r '.activation_message // (if (.display_code // "") != "" then "Plow Activate: " + .display_code else "" end)' "$activation_file" 2>/dev/null || true)"
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

start_channel_probe_daemon() {
  local state_file="$1" log_file="$2"
  PLOW_CHAT_STATE="$state_file" bun run --cwd "$PLOW_CHANNEL_DIR" --shell=bun --silent start >"$log_file" 2>&1 &
  printf '%s' "$!"
}

cmd_selftest() {
  require_tool bun
  require_tool curl
  require_tool jq
  [[ -x "$ACTIVATE_PIECE" ]] || {
    err "activate piece missing or not executable: $ACTIVATE_PIECE"
    return 1
  }
  [[ -f "$PLOW_STUB" ]] || {
    err "stub not found: $PLOW_STUB"
    return 1
  }

  local root stub_dir server_info base_url home state_file chat_uid text_pid activate_rc calls_file send_out probe_log probe_pid before_ws after_ws
  local group_home
  root="$(mktemp -d "${TMPDIR:-/tmp}/domo-ready-selftest.XXXXXX")"
  stub_dir="$root/stub"
  server_info="$stub_dir/server-info"
  home="$root/home"
  state_file="$home/.claude/plow-chat/state.json"
  calls_file="$root/calls.json"
  send_out="$root/ready-send.json"
  probe_log="$root/channel-probe.log"

  log "Starting Plow stub: $root"
  PLOW_STUB_STATE_DIR="$stub_dir" bun run "$PLOW_STUB" >"$root/stub.out" 2>"$root/stub.err" &
  PIDS+=("$!")
  wait_for_file "$server_info" 15 || {
    err "stub did not write server-info"
    return 1
  }
  base_url="$(jq -r '.base_url' "$server_info")"
  mkdir -p "$home"
  set_domo_home "$home"

  auto_text_stub_code "$base_url" "$home/.claude/plow-chat/activation.json" "$root/seen-codes" &
  text_pid="$!"
  PIDS+=("$text_pid")

  set +e
  PLOW_CHAT_BASE_URL="$base_url" \
  DOMO_HOME="$home" \
  DOMO_ACTIVATION_TIMEOUT_SECONDS=20 \
  DOMO_ACTIVATION_POLL_INTERVAL_SECONDS=1 \
    "$ACTIVATE_PIECE" activate >"$root/activate.out" 2>"$root/activate.err"
  activate_rc=$?
  set -e
  kill "$text_pid" >/dev/null 2>&1 || true
  [[ "$activate_rc" -eq 0 ]] || {
    err "Piece-3 stub activation failed rc=$activate_rc"
    sed 's/^/[domo-ready] activate stderr: /' "$root/activate.err" | tail -40
    return "$activate_rc"
  }

  validate_piece3_state
  write_default_config

  chat_uid="$(jq -r '.chat_uid' "$state_file")"
  before_ws="$(curl -fsS "$base_url/_stub/calls" | jq -r '.ws_connect // 0')"
  probe_pid="$(start_channel_probe_daemon "$state_file" "$probe_log")"
  PIDS+=("$probe_pid")
  local deadline=$(( $(date +%s) + 15 ))
  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    after_ws="$(curl -fsS "$base_url/_stub/calls" | jq -r '.ws_connect // 0')"
    if [[ "$after_ws" -gt "$before_ws" ]]; then break; fi
    sleep 0.2
  done
  after_ws="$(curl -fsS "$base_url/_stub/calls" | jq -r '.ws_connect // 0')"
  [[ "$after_ws" -gt "$before_ws" ]] || {
    err "channel probe daemon did not connect websocket"
    cat "$probe_log" >&2 || true
    return 1
  }

  send_ready_via_channel_tool "$state_file" "$READY_TEXT" "$base_url" "$chat_uid" "$send_out" >/dev/null

  curl -fsS "$base_url/_stub/calls" > "$calls_file"
  jq -e --arg chat_uid "$chat_uid" '
    .ws_connect >= 1
    and .outbound_messages >= 1
    and ([.sequence[] | select(.method == "POST") | .path] | index("/v1/chats/" + $chat_uid + "/messages") != null)
  ' "$calls_file" >/dev/null || {
    err "stub call sequence did not record ready outbound"
    return 1
  }
  curl -fsS "$base_url/_stub/messages?chat_uid=$(jq -rn --arg v "$chat_uid" '$v|@uri')" > "$root/messages.json"
  jq -e --arg body "$READY_TEXT" '
    (.data // []) | any(.direction == "outbound" and .body == $body)
  ' "$root/messages.json" >/dev/null || {
    err "stub messages did not include ready text"
    return 1
  }

  group_home="$root/group-ready-home"
  mkdir -p "$group_home"
  set_domo_home "$group_home"
  mkdir -p "$PLOW_DIR"
  jq -n '{base_url:"http://127.0.0.1:1", token:"group-token", chat_uid:"cht_group_ready"}' > "$PLOW_STATE_FILE"
  chmod 600 "$PLOW_STATE_FILE"
  jq -n '{
    interview:{mode:"group",status:"collected",members:["Alex","Pat"]},
    activation:"complete",
    activation_detail:{
      mode:"group",
      chat_active:true,
      participants:[
        {uid:"cp_ready_001",display_name:"Alex",status:"verified"},
        {uid:"cp_ready_002",display_name:"Pat",status:"verified"}
      ]
    }
  }' > "$INSTALL_STATE_FILE"
  chmod 600 "$INSTALL_STATE_FILE"
  write_default_config
  jq -e '
    .mode == "group"
    and (.system_prompt | contains("verified household group text"))
    and (.system_prompt | contains("Alex"))
    and (.system_prompt | contains("Pat"))
  ' "$READY_CONFIG_FILE" >/dev/null || {
    err "group ready config did not record group prompt/member names"
    jq . "$READY_CONFIG_FILE" >&2 || true
    return 1
  }
  grep -F "This is a group household" "$WORKSPACE/CLAUDE.md" >/dev/null || {
    err "group CLAUDE.md did not use group household prompt"
    return 1
  }

  log "PASS Piece-3 stub activation produced chmod-600 state: $state_file"
  log "PASS channel daemon connected: ws_connect $before_ws -> $after_ws"
  log "PASS ready text recorded by stub: $READY_TEXT"
  log "PASS group ready config authors group prompt with member names"
  log "PASS outbound call sequence: $(jq -r '[.sequence[].path] | join(" -> ")' "$calls_file")"
  log "Selftest artifacts: $root"
}

cmd_harness() {
  log "Isolated DOMO_HOME: $DOMO_HOME"
  log "Isolated CLAUDE_CONFIG_DIR: $CONFIG_DIR"
  if [[ "$CREATED_TEMP_HOME" == "1" ]]; then
    log "Created temp DOMO_HOME. For the real finale, pass the logged-in and activated DOMO_HOME from Pieces 1-3."
  fi
  log "One-command real ready harness:"
  printf '\n  DOMO_HOME=%s %s ready\n\n' "$(quote "$DOMO_HOME")" "$(quote "$SCRIPT_PATH")"
  cmd_ready "$@"
}

usage() {
  cat <<USAGE
Usage: DOMO_HOME=/logged-in-and-activated/domo-home $SCRIPT_PATH <command>

Commands:
  author    Write default Domo config and pinned session metadata
  start     Start the background Claude daemon with plow-chat loaded
  ready     Start daemon, then send deterministic first ready text via plow-chat reply
  harness   Print and run the one-command real ready harness
  status    Print non-secret readiness status
  stop      Stop the background daemon and sweep the channel child
  selftest  Stub chain: Piece-3 activation -> config -> channel connect -> ready text

If DOMO_HOME is omitted, a temp isolated home is created.
USAGE
}

case "${1:-harness}" in
  author) shift; require_tool jq; write_default_config "$@" ;;
  start) shift; cmd_start "$@" ;;
  ready) shift; cmd_ready "$@" ;;
  harness) shift; cmd_harness "$@" ;;
  status) shift; cmd_status "$@" ;;
  stop) shift; cmd_stop "$@" ;;
  selftest) shift; cmd_selftest "$@" ;;
  -h|--help|help) usage ;;
  *) err "unknown command '${1:-}'"; usage >&2; exit 2 ;;
esac
