#!/usr/bin/env bash
# client.sh — a tiny, agent-agnostic helper any driver can source to talk to the
# install dashboard server (ref/installer/server.ts) over its plain HTTP contract.
#
# It knows NOTHING about Domo, Claude, Plow, or connectors — only the generic
# server-info file and the /state, /answers, /events endpoints described in
# ref/installer/README.md. Source it, then call the functions below.
#
#   source ref/installer/client.sh
#   installer_url                       # http://127.0.0.1:PORT
#   installer_push "$(cat state.json)"  # POST full state object; echoes HTTP code
#   installer_wait_answers 120          # block until the page submits the form
#
# Requires: jq, curl. No secrets are read, stored, or printed by this helper.
set -euo pipefail

# Where server.ts writes its connection info. Matches the server's own default.
# INSTALLER_STATE_DIR is canonical; DOMO_INSTALLER_STATE_DIR is a back-compat alias.
INSTALLER_STATE_DIR="${INSTALLER_STATE_DIR:-${DOMO_INSTALLER_STATE_DIR:-${TMPDIR:-/tmp}/installer-ui}}"
_INSTALLER_SERVER_INFO="${INSTALLER_STATE_DIR%/}/server-info"

# --- internals -------------------------------------------------------------

# _installer_need <cmd>: fail with a clear message if a dependency is missing.
_installer_need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "client.sh: required command '$1' not found on PATH" >&2
    return 1
  }
}

# _installer_field <jq-path>: read one field out of server-info via jq.
# Errors (nonzero) if server-info is missing or the field is absent/empty.
_installer_field() {
  _installer_need jq
  if [ ! -f "$_INSTALLER_SERVER_INFO" ]; then
    echo "client.sh: server-info not found at $_INSTALLER_SERVER_INFO (is the installer running?)" >&2
    return 1
  fi
  local val
  val="$(jq -re "$1" "$_INSTALLER_SERVER_INFO")" || {
    echo "client.sh: field '$1' missing from $_INSTALLER_SERVER_INFO" >&2
    return 1
  }
  printf '%s' "$val"
}

# --- server-info accessors -------------------------------------------------

installer_url()         { _installer_field '.url'; }
installer_port()        { _installer_field '.port'; }
installer_token()       { _installer_field '.token'; }
installer_event_url()   { _installer_field '.events_url'; }
installer_events_url()  { _installer_field '.events_url'; }   # alias
installer_state_url()   { _installer_field '.state_url'; }
installer_answers_url() { _installer_field '.answers_url'; }

# installer_info: dump the whole server-info JSON (handy for debugging).
installer_info() {
  _installer_need jq
  [ -f "$_INSTALLER_SERVER_INFO" ] || {
    echo "client.sh: server-info not found at $_INSTALLER_SERVER_INFO" >&2
    return 1
  }
  jq '.' "$_INSTALLER_SERVER_INFO"
}

# --- state push ------------------------------------------------------------

# installer_push '<state-json>': POST the FULL state object to state_url.
# Echoes the HTTP status code. Exits nonzero on >=400 so a no-secret rejection
# (the server's 400) is visible to the caller. The body is the contract object
# from ref/installer/README.md — it must contain NO secrets.
installer_push() {
  _installer_need curl
  local body="${1:-}"
  if [ -z "$body" ]; then
    echo "client.sh: installer_push requires a JSON state object argument" >&2
    return 2
  fi
  local url code
  url="$(installer_state_url)" || return 1
  # --data-binary so the JSON is sent verbatim; capture only the HTTP code.
  code="$(curl -sS -o /dev/null -w '%{http_code}' \
    -X POST "$url" \
    -H 'Content-Type: application/json' \
    --data-binary "$body")" || {
    echo "client.sh: POST to state_url failed (network/curl error)" >&2
    return 1
  }
  echo "$code"
  if [ "$code" -ge 400 ]; then
    echo "client.sh: state POST rejected with HTTP $code (secret in state? bad JSON?)" >&2
    return 1
  fi
  return 0
}

# --- answers ---------------------------------------------------------------

# installer_answers: GET answers_url and print the JSON the page submitted:
#   { "submitted": bool, "values": {…} }
installer_answers() {
  _installer_need curl
  local url
  url="$(installer_answers_url)" || return 1
  curl -sS "$url"
}

# installer_wait_answers [timeout_seconds]: poll answers_url until
# .submitted == true (default timeout 300s). On success, prints .values (JSON)
# and returns 0. On timeout, returns 1.
installer_wait_answers() {
  _installer_need curl
  _installer_need jq
  local timeout="${1:-300}"
  local url
  url="$(installer_answers_url)" || return 1
  local waited=0 body submitted
  while :; do
    body="$(curl -sS "$url" 2>/dev/null || true)"
    if [ -n "$body" ]; then
      submitted="$(printf '%s' "$body" | jq -r '.submitted // false' 2>/dev/null || echo false)"
      if [ "$submitted" = "true" ]; then
        printf '%s' "$body" | jq '.values'
        return 0
      fi
    fi
    if [ "$waited" -ge "$timeout" ]; then
      echo "client.sh: timed out after ${timeout}s waiting for form submission" >&2
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
}

# If sourced, the functions above are now available. If executed directly,
# treat argv[1] as a function name to run (e.g. `client.sh installer_url`).
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  if [ "$#" -gt 0 ]; then
    fn="$1"; shift
    "$fn" "$@"
  else
    echo "client.sh: source me, or run: client.sh <function> [args]" >&2
    echo "functions: installer_url installer_port installer_token installer_event_url" >&2
    echo "           installer_state_url installer_answers_url installer_info" >&2
    echo "           installer_push installer_answers installer_wait_answers" >&2
    exit 2
  fi
fi
