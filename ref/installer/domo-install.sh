#!/usr/bin/env bash
# domo-install.sh - Phase 0/1 bootstrap driver for Domo's install UX.
#
# Runs the install sequence: fail-fast tooling check, `domo setup`, dashboard
# launch, one terminal interview question, activation, preflight, authoring, and
# daemon start.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
DOMO_HOME="${DOMO_HOME:-$REPO_ROOT}"
export DOMO_HOME
DOMO="${DOMO:-$REPO_ROOT/ref/domo}"
CLIENT="$HERE/client.sh"
START="$HERE/start.sh"
INSTALL_STATE_FILE="$DOMO_HOME/install-state.json"
DOMO_LOG_FILE="$DOMO_HOME/.claude/run/domo.log"
DOMO_META_FILE="$DOMO_HOME/.claude/domo.json"
DOMO_WORKSPACE="$DOMO_HOME/workspace"
DOMO_WORKSPACE_SLUG="$(printf '%s' "$DOMO_WORKSPACE" | sed 's/[\/.]/-/g')"
DOMO_PROJECTS_DIR="$DOMO_HOME/.claude/projects/$DOMO_WORKSPACE_SLUG"
PREFLIGHT_INTERVAL_SECONDS="${DOMO_PREFLIGHT_INTERVAL_SECONDS:-5}"
PREFLIGHT_MAX_ATTEMPTS="${DOMO_PREFLIGHT_MAX_ATTEMPTS:-0}"
CALENDAR_PROBE_TIMEOUT_SECONDS="${DOMO_CALENDAR_PROBE_TIMEOUT_SECONDS:-45}"
PREFLIGHT_CONFIRMED_THIS_RUN=0
INSTALL_RUN_TMP_DIR=""

PROMPT="Solo or group? If group, who's in the household? (names — include yourself)"
BANNER="One quick question is waiting in your terminal — answer it to continue."

log() { printf '[domo-install] %s\n' "$*"; }
die() { printf '[domo-install] ERROR: %s\n' "$*" >&2; exit 1; }
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

state_defaults_filter='
  . as $prev
  | .interview = (
      if (.interview | type) == "object" then
        .interview + {
          status: (.interview.status // (if .interview.mode then "collected" else "pending" end)),
          members: (.interview.members // [])
        }
      else {status:"pending", members:[]} end
    )
  | .activation = (.activation // "pending")
  | .login = (.login // "pending")
  | .calendar = (.calendar // "pending")
  | .build = (.build // "pending")
  | .ready = (.ready // false)
'

write_state_jq() {
  mkdir -p "$DOMO_HOME"
  local filter="$1"; shift
  local tmp
  tmp="$(umask 077; mktemp "$DOMO_HOME/.install-state.json.XXXXXX")"
  if [[ -f "$INSTALL_STATE_FILE" ]]; then
    if ! jq "$@" "$state_defaults_filter | $filter" "$INSTALL_STATE_FILE" > "$tmp"; then
      rm -f "$tmp"
      die "cannot read/parse $INSTALL_STATE_FILE; refusing to overwrite install state because it may hold one-time activation codes"
    fi
  else
    jq -n "$@" "{} | $state_defaults_filter | $filter" > "$tmp"
  fi
  chmod 600 "$tmp"
  mv -f "$tmp" "$INSTALL_STATE_FILE"
}

init_install_state() {
  write_state_jq '.'
}

state_get() {
  local expr="$1"
  jq -r "$expr // empty" "$INSTALL_STATE_FILE" 2>/dev/null || true
}

set_state_field() {
  local field="$1" value="$2"
  write_state_jq '.[$field]=$value' --arg field "$field" --arg value "$value"
}

set_state_bool() {
  local field="$1" value="$2"
  write_state_jq '.[$field]=($value == "true")' --arg field "$field" --arg value "$value"
}

set_state_message() {
  local message="$1"
  write_state_jq '.message=$message' --arg message "$message"
}

dashboard_state_json() {
  local login_command="$DOMO login"
  local login_pending_message="Claude login didn't complete — run domo login in a new terminal."
  jq -n \
    --arg banner "$BANNER" \
    --arg prompt "$PROMPT" \
    --arg loginCommand "$login_command" \
    --arg loginPendingMessage "$login_pending_message" \
    --slurpfile ss "$INSTALL_STATE_FILE" \
    '{
      state: (($ss[0] // {}) as $raw
        | $raw
        | .interview = (
            if (.interview | type) == "object" then
              .interview + {
                status: (.interview.status // (if .interview.mode then "collected" else "pending" end)),
                members: (.interview.members // [])
              }
            else {status:"pending", members:[]} end
          )
        | .activation = (.activation // "pending")
        | .login = (.login // "pending")
        | .calendar = (.calendar // "pending")
        | .build = (.build // "pending")
        | .ready = (.ready // false))
    } | .state as $st |
    if $st.ready == true then {
      title: "Domo is live",
      kicker: "Ready",
      subtitle: ("Domo is live — text " + (($st.live_number // $st.activation_detail.owner.send_to // $st.activation_detail.send_to // $st.activation_detail.line.provider_key // $st.activation_detail.chat.provider_key // "the Domo number") | tostring) + " to talk to it."),
      message: "Daemon confirmed responding.",
      done: true
    } else {
      title: "Setting up Domo",
      kicker: "Preparing Domo",
      subtitle: (if $st.interview.status == "collected" then
          "Domo is watching the remaining checks and will continue on its own."
        else "The dashboard is ready. Answer the terminal question so setup can continue." end),
      message: ($st.message // (if $st.interview.status == "collected" then "" else $banner end)),
      done: false,
      steps: [
        { id: "tooling", status: "ok", label: "Tooling check passed" },
        { id: "setup", status: "ok", label: "Domo shell prepared" },
        {
          id: "interview",
          status: (if $st.interview.status == "collected" then "ok" else "waiting" end),
          label: (if $st.interview.status == "collected" then "Household shape collected" else $prompt end),
          action: (if $st.interview.status == "collected" then null else {
            instruction: $prompt,
            where: "terminal"
          } end)
        },
        {
          id: "login",
          status: (if $st.login == "confirmed" then "ok" else "waiting" end),
          label: "Sign in to Claude",
          detail: (if $st.login == "confirmed" then
              "Confirmed by a fresh Domo session readiness marker."
            else $loginPendingMessage end),
          action: (if $st.login == "confirmed" then null else {
            instruction: "Open a NEW terminal, paste this command, and complete the Claude browser login there.",
            where: "terminal",
            command: $loginCommand
          } end)
        },
        {
          id: "calendar",
          status: (if $st.calendar == "confirmed" then "ok" else "waiting" end),
          label: "Enable Google Calendar",
          detail: (if $st.calendar == "confirmed" then
              "Confirmed by probing Google Calendar tools inside the logged-in Domo session."
            else "Waiting — connect Google Calendar on the same Anthropic account, then Domo will confirm it." end),
          action: (if $st.calendar == "confirmed" then null else {
            instruction: "Connect Google Calendar on the same Anthropic account you use for domo login.",
            where: "browser",
            link: "https://claude.ai/customize/connectors"
          } end)
        },
        {
          id: "plow",
          status: (if $st.activation == "complete" then "ok" else "waiting" end),
          label: (if $st.activation == "complete" then "Plow chat active" else "Activate Plow chat — text the code" end),
          detail: (if $st.activation == "complete" then "Verified from the activation state file." else "Waiting for the activation text verification." end)
        },
        {
          id: "author",
          status: (if $st.build == "complete" then "ok" elif ($st.login == "confirmed" and $st.calendar == "confirmed" and $st.activation == "complete") then "active" else "pending" end),
          label: (if $st.build == "complete" then "Custom Domo authored" else "Author custom Domo" end)
        },
        {
          id: "start",
          status: (if $st.ready == true then "ok" elif $st.build == "complete" then "active" else "pending" end),
          label: (if $st.ready == true then "Daemon responding" else "Start Domo daemon" end)
        }
      ],
      verification: (
        if ($st.activation_detail.mode // "") == "group" then
          ([{
            id: "owner",
            name: "Owner",
            status: (if ($st.activation_detail.owner.status // "") == "verified" then "verified" else "pending" end),
            code: ($st.activation_detail.owner.display_code // ""),
            number: ($st.activation_detail.owner.send_to // ""),
            isSelf: true
          }] + [($st.activation_detail.participants // [])[] | {
            id: .uid,
            name: .display_name,
            status: (if .status == "verified" then "verified" else "pending" end),
            code: (.verification_code // ""),
            number: (.provider_key // $st.activation_detail.chat.provider_key // $st.activation_detail.line.provider_key // "")
          }])
        elif ($st.activation_detail.mode // "") == "solo" then
          [{
            id: "solo",
            name: "You",
            status: (if $st.activation == "complete" then "verified" else "pending" end),
            code: ($st.activation_detail.display_code // ""),
            number: ($st.activation_detail.send_to // ""),
            isSelf: true
          }]
        else null end)
    } end'
}

push_dashboard_from_state() {
  local state
  state="$(dashboard_state_json)"
  printf '%s\n' "$state" > "$INSTALLER_STATE_DIR/state.json"
  "$CLIENT" installer_push "$state" >/dev/null || true
}

mark_interview_collected() {
  push_dashboard_from_state
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

  write_state_jq '
    .interview = {
      status: "collected",
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
    | .message = ""
  ' --arg mode "$mode" --arg raw "$names"
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

state_is_interview_collected() {
  [[ "$(state_get '.interview.status')" == "collected" ]]
}

state_activation_complete() {
  [[ "$(state_get '.activation')" == "complete" ]]
}

state_ready() {
  [[ "$(state_get '.ready')" == "true" ]]
}

file_size() {
  local file="$1"
  [[ -f "$file" ]] || { printf '0'; return 0; }
  stat -f '%z' "$file" 2>/dev/null || stat -c '%s' "$file" 2>/dev/null || printf '0'
}

fresh_log_has_channel_marker() {
  local offset="$1"
  [[ -f "$DOMO_LOG_FILE" ]] || return 1
  dd if="$DOMO_LOG_FILE" bs=1 skip="$offset" 2>/dev/null \
    | perl -pe 's/\e\[[0-9;?]*[ -\/]*[@-~]//g; s/\r//g' \
    | grep -qiE 'Listening for channel|channel messages from'
}

wait_for_fresh_channel_marker() {
  local offset="$1" seconds="${2:-20}" i
  for i in $(seq 1 "$seconds"); do
    fresh_log_has_channel_marker "$offset" && return 0
    sleep 1
  done
  return 1
}

stop_domo_quietly() {
  "$DOMO" stop >/dev/null 2>&1 || true
}

start_and_wait_for_fresh_marker() {
  local offset rc out
  offset="$(file_size "$DOMO_LOG_FILE")"
  set +e
  out="$("$DOMO" start 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out"
  [[ "$rc" -eq 0 ]] || return "$rc"
  wait_for_fresh_channel_marker "$offset" "${DOMO_PREFLIGHT_MARKER_WAIT_SECONDS:-20}"
}

calendar_transcript_path() {
  local sid
  sid="$(jq -r '.session_id // empty' "$DOMO_META_FILE" 2>/dev/null || true)"
  [[ -n "$sid" ]] || return 1
  printf '%s/%s.jsonl' "$DOMO_PROJECTS_DIR" "$sid"
}

calendar_tool_result_confirmed() {
  local transcript="$1" offset="$2"
  [[ -f "$transcript" ]] || return 1
  TRANSCRIPT_FILE="$transcript" TRANSCRIPT_OFFSET="$offset" bun -e '
    const fs = require("fs");
    const file = process.env.TRANSCRIPT_FILE;
    const offset = Number(process.env.TRANSCRIPT_OFFSET || 0);
    let data = "";
    try { data = fs.readFileSync(file, "utf8").slice(offset); } catch { process.exit(1); }
    const calendarTool = "mcp__claude_ai_Google_Calendar__list_calendars";
    const toolIds = new Set();
    let sawCalendarTool = false;
    let confirmed = false;
    function flatten(value) {
      if (value == null) return "";
      if (typeof value === "string") return value;
      if (Array.isArray(value)) return value.map(flatten).join("\n");
      if (typeof value === "object") {
        if (typeof value.text === "string") return value.text;
        return JSON.stringify(value);
      }
      return String(value);
    }
    for (const line of data.split(/\n/)) {
      if (!line.trim()) continue;
      let event;
      try { event = JSON.parse(line); } catch { continue; }
      const content = event?.message?.content;
      if (!Array.isArray(content)) continue;
      for (const item of content) {
        if (item?.type === "tool_use" && item?.name === calendarTool) {
          sawCalendarTool = true;
          if (item.id) toolIds.add(item.id);
        }
        if (item?.type === "tool_result" && item?.is_error !== true) {
          const linked = item.tool_use_id ? toolIds.has(item.tool_use_id) : sawCalendarTool;
          const text = flatten(item.content).trim();
          if (linked && text.length > 2 && !/(permission denied|not found|failed|error|missing)/i.test(text)) {
            confirmed = true;
          }
        }
      }
    }
    process.exit(confirmed ? 0 : 1);
  '
}

probe_calendar_in_session() {
  if [[ -n "${DOMO_PREFLIGHT_CALENDAR_CMD:-}" && "${DOMO_TEST_ALLOW_FAKE_CALENDAR_PROBE:-0}" == "1" ]]; then
    bash -c "$DOMO_PREFLIGHT_CALENDAR_CMD"
    return $?
  elif [[ -n "${DOMO_PREFLIGHT_CALENDAR_CMD:-}" ]]; then
    log "ignoring DOMO_PREFLIGHT_CALENDAR_CMD because DOMO_TEST_ALLOW_FAKE_CALENDAR_PROBE is not set"
  fi

  local sid transcript offset out err rc
  sid="$(jq -r '.session_id // empty' "$DOMO_META_FILE" 2>/dev/null || true)"
  [[ -n "$sid" ]] || return 1
  transcript="$(calendar_transcript_path)" || return 1
  offset="$(file_size "$transcript")"
  out="$INSTALL_RUN_TMP_DIR/calendar-probe.out"
  err="$INSTALL_RUN_TMP_DIR/calendar-probe.err"
  set +e
  (
    export CLAUDE_CONFIG_DIR="$DOMO_HOME/.claude"
    unset ANTHROPIC_API_KEY
    cd "$DOMO_WORKSPACE"
    perl -e 'alarm shift; exec @ARGV' "$CALENDAR_PROBE_TIMEOUT_SECONDS" \
      claude -p --resume "$sid" --permission-mode "${DOMO_PERMISSION_MODE:-auto}" \
        'Call mcp__claude_ai_Google_Calendar__list_calendars now. After the tool result returns, summarize the number of calendars and one calendar name or id. Do not claim success unless the tool result is available.'
  ) >"$out" 2>"$err"
  rc=$?
  set -e
  [[ "$rc" -eq 0 ]] || return 1
  calendar_tool_result_confirmed "$transcript" "$offset"
}

run_preflight_once() {
  local started=0 rc=1 preflight_out
  preflight_out="$INSTALL_RUN_TMP_DIR/preflight-start.out"
  push_dashboard_from_state

  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    set_state_field login "pending"
    set_state_message "unset ANTHROPIC_API_KEY — Domo uses your subscription, not an API key"
    push_dashboard_from_state
    log "preflight blocked: ANTHROPIC_API_KEY is set"
    return 1
  fi

  log "preflight: starting Domo session and waiting for a fresh channel marker"
  stop_domo_quietly
  if start_and_wait_for_fresh_marker >"$preflight_out"; then
    started=1
    set_state_field login "confirmed"
    set_state_message ""
    push_dashboard_from_state
  else
    set_state_field login "pending"
    set_state_message "Claude login didn't complete — run domo login in a new terminal."
    push_dashboard_from_state
    log "preflight: login still pending; run domo login in a new terminal"
    stop_domo_quietly
    return 1
  fi

  log "preflight: probing Google Calendar tools inside the logged-in Domo session"
  if probe_calendar_in_session; then
    set_state_field calendar "confirmed"
    set_state_message ""
    push_dashboard_from_state
    PREFLIGHT_CONFIRMED_THIS_RUN=1
    rc=0
  else
    set_state_field calendar "pending"
    set_state_message "Google Calendar connector not confirmed — connect it on the same Anthropic account."
    push_dashboard_from_state
    log "preflight: calendar still pending"
    rc=1
  fi

  [[ "$started" -eq 1 ]] && stop_domo_quietly
  return "$rc"
}

author_domo() {
  mkdir -p "$DOMO_WORKSPACE"
  local tmp mode members
  mode="$(state_get '.interview.mode')"
  members="$(jq -r '(.interview.members // []) | join(", ")' "$INSTALL_STATE_FILE")"
  tmp="$(mktemp "$DOMO_WORKSPACE/.CLAUDE.md.XXXXXX")"
  {
    printf '# Domo\n\n'
    printf 'You are Domo, a household assistant reached by text through the Plow Chat channel.\n'
    printf 'Always send user-visible replies with the channel reply tool; transcript text alone does not reach the household.\n'
    printf 'Use Google Calendar tools for calendar questions, scheduling, and date/time checks.\n\n'
    printf 'Household mode: %s\n' "${mode:-solo}"
    if [[ "$mode" == "group" && -n "$members" ]]; then
      printf 'Household members: %s\n' "$members"
    fi
  } > "$tmp"
  mv -f "$tmp" "$DOMO_WORKSPACE/CLAUDE.md"
}

live_number_from_state() {
  jq -r '
    .activation_detail.owner.send_to
    // .activation_detail.send_to
    // .activation_detail.line.provider_key
    // .activation_detail.chat.provider_key
    // empty
  ' "$INSTALL_STATE_FILE"
}

mark_ready() {
  local number="$1"
  write_state_jq '.ready=true | .build="complete" | .live_number=$number | .message=""' --arg number "$number"
  push_dashboard_from_state
}

author_start_and_verify() {
  local start_out
  start_out="$INSTALL_RUN_TMP_DIR/final-start.out"
  log "preflight passed: authoring Domo and starting the daemon"
  set_state_field build "active"
  set_state_message "Authoring custom Domo."
  push_dashboard_from_state

  author_domo
  set_state_message "Starting Domo daemon."
  push_dashboard_from_state

  stop_domo_quietly
  if ! start_and_wait_for_fresh_marker >"$start_out"; then
    stop_domo_quietly
    set_state_field build "pending"
    set_state_message "Domo start did not confirm a fresh channel marker; check domo logs."
    push_dashboard_from_state
    log "start failed to verify; output follows"
    sed 's/^/[domo-install] start: /' "$start_out" >&2 || true
    return 1
  fi

  local number
  number="$(live_number_from_state)"
  mark_ready "$number"
  log "success: Domo is live — text ${number:-the Domo number}"
}

run_build_while_away() {
  local attempt=0
  while :; do
    if state_ready; then
      push_dashboard_from_state
      log "ready: $(state_get '.live_number')"
      return 0
    fi
    if [[ "$PREFLIGHT_CONFIRMED_THIS_RUN" == "1" && "$(state_get '.login')" == "confirmed" && "$(state_get '.calendar')" == "confirmed" && "$(state_get '.activation')" == "complete" ]]; then
      author_start_and_verify
      return $?
    fi
    attempt=$((attempt + 1))
    run_preflight_once || true
    if [[ "$PREFLIGHT_CONFIRMED_THIS_RUN" == "1" && "$(state_get '.login')" == "confirmed" && "$(state_get '.calendar')" == "confirmed" && "$(state_get '.activation')" == "complete" ]]; then
      author_start_and_verify
      return $?
    fi
    if [[ "$PREFLIGHT_MAX_ATTEMPTS" -gt 0 && "$attempt" -ge "$PREFLIGHT_MAX_ATTEMPTS" ]]; then
      log "preflight incomplete after $attempt attempt(s); rerun the installer to resume from $INSTALL_STATE_FILE"
      return 1
    fi
    sleep "$PREFLIGHT_INTERVAL_SECONDS"
  done
}

main() {
  local elapsed0 t1 t2 url answer
  INSTALL_RUN_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/domo-install-run.XXXXXX")"
  trap 'rm -rf "$INSTALL_RUN_TMP_DIR"' EXIT
  elapsed0="$SECONDS"
  check_tooling
  t1="$(date +%s)"
  log "tooling-pass t=${t1} elapsed=$((SECONDS - elapsed0))s"

  prepare_installer_state_dir

  "$DOMO" setup >/dev/null 2>&1
  init_install_state

  INSTALLER_NO_OPEN=1 "$START" >/dev/null
  url="$(dashboard_url)"
  push_dashboard_from_state
  open_dashboard "$url"
  t2="$(date +%s)"
  log "dashboard-reachable t=${t2} elapsed-from-tooling=$((t2 - t1))s url=$url"

  if ! state_is_interview_collected; then
    printf '%s\n' "$PROMPT"
    IFS= read -r answer
    persist_interview "$answer"
    mark_interview_collected
    log "$(interview_summary)"
  else
    log "resuming from $INSTALL_STATE_FILE: $(interview_summary)"
    push_dashboard_from_state
  fi

  if ! state_activation_complete; then
    set_state_message "Activating Plow chat."
    push_dashboard_from_state
    local activate_rc_file activate_rc
    activate_rc_file="$INSTALL_RUN_TMP_DIR/activate.rc"
    (
      set +e
      DOMO_DASHBOARD_MIRROR_STATE=1 "$DOMO" activate
      printf '%s\n' "$?" > "$activate_rc_file"
    ) &
    local activate_pid=$!
    while [[ ! -f "$activate_rc_file" ]]; do
      push_dashboard_from_state
      sleep 1
    done
    wait "$activate_pid" || true
    activate_rc="$(cat "$activate_rc_file")"
    [[ "$activate_rc" -eq 0 ]] || return "$activate_rc"
    push_dashboard_from_state
  else
    log "activation: complete (from persisted state)"
    push_dashboard_from_state
  fi

  run_build_while_away
}

main "$@"
