#!/usr/bin/env bash
# E2E install repro for the install-UX flow.
#
# Runs solo and group installs through the real install action entry point
# (`ref/installer/domo-install.sh`) against `plow-stub.ts`. It uses an isolated
# DOMO_HOME and a fake Claude CLI so CI/local runs do not need a real Claude
# login or SMS provider.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
ENTRYPOINT="$HERE/domo-install.sh"
PLOW_STUB="$HERE/plow-stub.ts"
CURRENT_ROOT=""
CURRENT_STUB_PID=""
CURRENT_TEXT_PID=""

log() { printf '[e2e] %s\n' "$*"; }
fail() { printf '[e2e] FAIL: %s\n' "$*" >&2; exit 1; }

need_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required tool: $1"
}

perm_of() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null
}

assert_file_perm_600() {
  local file="$1" perm
  [[ -f "$file" ]] || fail "missing file: $file"
  perm="$(perm_of "$file")"
  [[ "$perm" == "600" ]] || fail "$file permissions are $perm, expected 600"
}

assert_jq() {
  local file="$1" expr="$2" label="$3"
  jq -e "$expr" "$file" >/dev/null || fail "$label"
}

make_fake_claude() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  echo "2.1.157"
  exit 0
fi
if [[ "${1:-}" == "mcp" ]]; then
  exit 0
fi
if [[ "${1:-}" == "-p" ]]; then
  echo "Calendar probe ok"
  exit 0
fi
trap 'exit 0' TERM INT HUP
echo "Listening for channel messages from plow-chat"
echo "Domo test daemon responding"
while :; do sleep 1; done
SH
  chmod +x "$bin_dir/claude"
}

wait_for_stub() {
  local info="$1"
  for _ in $(seq 1 80); do
    [[ -f "$info" ]] && return 0
    sleep 0.1
  done
  return 1
}

stop_dashboard() {
  local info="$1" port pids
  [[ -f "$info" ]] || return 0
  port="$(jq -r '.port // empty' "$info" 2>/dev/null || true)"
  [[ -n "$port" ]] || return 0
  command -v lsof >/dev/null 2>&1 || return 0
  pids="$(lsof -nP -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)"
  [[ -z "$pids" ]] || kill $pids 2>/dev/null || true
}

cleanup_current() {
  local root="${CURRENT_ROOT:-}" stub_pid="${CURRENT_STUB_PID:-}" text_pid="${CURRENT_TEXT_PID:-}"
  [[ -n "$text_pid" ]] && { kill "$text_pid" 2>/dev/null || true; wait "$text_pid" 2>/dev/null || true; }
  if [[ -n "$root" ]]; then
    PATH="$root/bin:$PATH" DOMO_HOME="$root/home" "$REPO_ROOT/ref/domo" stop >/dev/null 2>&1 || true
    stop_dashboard "$root/installer-ui/server-info"
  fi
  [[ -n "$stub_pid" ]] && { kill "$stub_pid" 2>/dev/null || true; wait "$stub_pid" 2>/dev/null || true; }
  CURRENT_ROOT=""
  CURRENT_STUB_PID=""
  CURRENT_TEXT_PID=""
}

trap cleanup_current EXIT

auto_text_codes() {
  local base_url="$1" home="$2" seen_file="$3"
  touch "$seen_file"
  while :; do
    local state="$home/install-state.json" ws_ticket_count="0"
    if [[ -f "$state" ]]; then
      ws_ticket_count="$(curl -fsS "$base_url/_stub/calls" 2>/dev/null | jq -r '.ws_ticket // 0' 2>/dev/null || printf '0')"
      jq -r '.. | objects | (.display_code? // empty), (.verification_code? // empty)' "$state" 2>/dev/null \
        | awk 'NF' \
        | while IFS= read -r code; do
            if grep -qxF "$code" "$seen_file"; then
              continue
            fi
            if [[ "$code" == VERIFY-* && "$ws_ticket_count" == "0" ]]; then
              continue
            fi
            printf '%s\n' "$code" >> "$seen_file"
            jq -nc --arg text "$code" --arg from "+1555010${RANDOM}" '{text:$text, from:$from}' \
              | curl -fsS -X POST "$base_url/_stub/text" -H 'Content-Type: application/json' -d @- >/dev/null || true
          done
    fi
    sleep 0.2
  done
}

assert_state_file_shape() {
  local state_file="$1" base_url="$2"
  assert_file_perm_600 "$state_file"
  jq -e --arg base "$base_url" '
    .base_url == $base
    and (.token | type == "string" and startswith("plow_stub_token_"))
    and (.chat_uid | type == "string" and startswith("cht_"))
    and (keys | sort == ["base_url","chat_uid","token"])
  ' "$state_file" >/dev/null || fail "channel state file shape invalid: $state_file"
}

assert_install_result() {
  local mode="$1" root="$2" base_url="$3"
  local home="$root/home" calls_file="$root/calls.json" status_out="$root/status.out"
  local log_file="$home/.claude/run/domo.log"
  curl -fsS "$base_url/_stub/calls" > "$calls_file"

  assert_file_perm_600 "$home/install-state.json"
  assert_state_file_shape "$home/.claude/plow-chat/state.json" "$base_url"
  assert_jq "$home/install-state.json" '.ready == true and .activation == "complete" and .login == "confirmed" and .calendar == "confirmed" and .build == "complete"' "$mode install did not reach ready state"

  PATH="$root/bin:$PATH" DOMO_HOME="$home" "$REPO_ROOT/ref/domo" status >"$status_out" 2>&1
  grep -q 'daemon:          ALIVE' "$status_out" || fail "$mode daemon not alive"
  grep -q 'plow-chat state: present' "$status_out" || fail "$mode channel state not present in status"
  grep -q 'Domo test daemon responding' "$log_file" || fail "$mode daemon did not emit responding marker"

  if [[ "$mode" == "solo" ]]; then
    jq -e '
      .activate == 1
      and .redeem >= 1
      and .lines == 0
      and .chats == 0
      and .resend == 0
      and .ws_ticket == 0
      and .ws_connect == 0
      and .sequence[0].path == "/v1/auth/activate"
      and ([.sequence[].path] | index("/v1/auth/activate/redeem") != null)
    ' "$calls_file" >/dev/null || fail "solo Plow call sequence invalid"
    assert_jq "$home/install-state.json" '.activation_detail.mode == "solo" and .live_number == "+15550001003"' "solo state shape invalid"
  else
    jq -e '
      .activate == 1
      and .redeem >= 1
      and .lines == 1
      and .chats == 1
      and .resend == 0
      and .ws_ticket >= 1
      and .ws_connect >= 1
      and ([.sequence[].path] as $s
        | ($s | index("/v1/auth/activate")) as $a
        | ($s | index("/v1/auth/activate/redeem")) as $r
        | ($s | index("/v1/lines")) as $l
        | ($s | index("/v1/chats")) as $c
        | ($s | index("/v1/ws/ticket")) as $w
        | ($s | index("/v1/ws")) as $ws
        | $a != null and $r != null and $l != null and $c != null and $w != null and $ws != null
        and $a < $r and $r < $l and $l < $c and $c < $w and $w < $ws)
    ' "$calls_file" >/dev/null || fail "group Plow call sequence invalid"
    assert_jq "$home/install-state.json" '
      .activation_detail.mode == "group"
      and .activation_detail.chat_active == true
      and ((.activation_detail.participants // []) | length >= 2)
      and all(.activation_detail.participants[]; .status == "verified")
      and all(.activation_detail.chat.participants[]?; (.type != "member") or (.status == "active"))
    ' "group state shape invalid"
  fi
}

run_case() {
  local mode="$1" answer="$2"
  local root base_url stub_pid="" text_pid="" rc
  root="$(mktemp -d /tmp/domo-install-e2e-${mode}.XXXXXX)"
  CURRENT_ROOT="$root"
  mkdir -p "$root/stub" "$root/home"
  make_fake_claude "$root/bin"

  PLOW_STUB_STATE_DIR="$root/stub" bun run "$PLOW_STUB" >"$root/stub.out" 2>"$root/stub.err" &
  stub_pid=$!
  CURRENT_STUB_PID="$stub_pid"
  wait_for_stub "$root/stub/server-info" || fail "$mode stub did not start"
  base_url="$(jq -r .base_url "$root/stub/server-info")"
  auto_text_codes "$base_url" "$root/home" "$root/seen-codes" &
  text_pid=$!
  CURRENT_TEXT_PID="$text_pid"

  log "$mode: entering install action $ENTRYPOINT"
  set +e
  PATH="$root/bin:$PATH" \
  DOMO_HOME="$root/home" \
  DOMO_INSTALL_TEST_MODE=1 \
  DOMO_PREFLIGHT_CALENDAR_CMD=true \
  DOMO_PREFLIGHT_MARKER_WAIT_SECONDS=3 \
  DOMO_PREFLIGHT_MAX_ATTEMPTS=1 \
  DOMO_ACTIVATION_TIMEOUT_SECONDS=5 \
  DOMO_ACTIVATION_POLL_INTERVAL_SECONDS=1 \
  DOMO_WS_TIMEOUT_MS=12000 \
  INSTALLER_NO_OPEN=1 \
  INSTALLER_STATE_DIR="$root/installer-ui" \
  PLOW_CHAT_BASE_URL="$base_url" \
  "$ENTRYPOINT" >"$root/install.out" 2>"$root/install.err" <<EOF
$answer
EOF
  rc=$?
  set -e
  [[ "$rc" -eq 0 ]] || {
    tail -n 80 "$root/install.out" >&2 || true
    tail -n 80 "$root/install.err" >&2 || true
    fail "$mode install exited $rc (artifacts: $root)"
  }

  assert_install_result "$mode" "$root" "$base_url"
  log "$mode: PASS ready=$(jq -r .ready "$root/home/install-state.json") live_number=$(jq -r .live_number "$root/home/install-state.json") calls=$(jq -c '.sequence' "$root/calls.json")"
  cleanup_current
}

main() {
  need_tool bun
  need_tool jq
  need_tool curl
  need_tool expect

  case "${1:-all}" in
    solo) run_case solo "solo" ;;
    group) run_case group "group: Pat, Riley" ;;
    all) run_case solo "solo"; run_case group "group: Pat, Riley" ;;
    *) fail "usage: $0 [solo|group|all]" ;;
  esac
}

main "$@"
