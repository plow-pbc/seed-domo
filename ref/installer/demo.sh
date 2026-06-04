#!/usr/bin/env bash
# demo.sh — a self-contained happy-path that drives the install dashboard through
# every phase WITHOUT a human, so a watcher (the browser SPA) sees it animate, and
# so the installer is validated end-to-end.
#
# It assumes the server (ref/installer/server.ts) is ALREADY running — i.e.
# server-info exists. It sources client.sh for the HTTP plumbing and pushes the
# EXACT contract shape from ref/installer/README.md on each step.
#
# Two parts:
#   1. A scripted walk through the Domo install phases (always runs).
#   2. A REAL Plow verification leg (only if DOMO_PLOW_TOKEN is set), against a
#      configurable API + TWIN base URL. If the token is unset, the live leg is
#      skipped and a simulated verified panel is pushed instead.
#
# SECURITY: DOMO_PLOW_TOKEN comes ONLY from the environment — it is NEVER
# hardcoded, never put into a pushed state object, and never logged. The state
# objects carry only display data and the one-time VERIFY-XXXXXX codes (which are
# meant to be shown). The server rejects any state body containing a secret.
set -euo pipefail

# Resolve this script's directory so we can source the sibling client.sh.
_DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=client.sh
source "${_DEMO_DIR}/client.sh"

# Configurable Plow endpoints (local fakes by default; never the real api.plow.co).
PLOW_API="${DOMO_PLOW_API:-http://127.0.0.1:19004}"
PLOW_TWIN="${DOMO_PLOW_TWIN:-http://127.0.0.1:19005}"

STEP_SLEEP="${DOMO_DEMO_STEP_SLEEP:-1}"

# A friendly display line number used by the simulated phases / fallback panel.
SIM_LINE_NUMBER="+15555550101"

log() { printf '[demo] %s\n' "$*" >&2; }

# push <state-json>: push one contract state object and report the HTTP code.
push() {
  local code
  code="$(installer_push "$1")" || {
    log "state push FAILED (HTTP ${code:-?}) — aborting"
    return 1
  }
  log "pushed state (HTTP $code)"
  sleep "$STEP_SLEEP"
}

# ---------------------------------------------------------------------------
# Part 1 — scripted walk through the phases. Each block is the FULL state object
# (the contract is replace-the-whole-thing on every change).
# ---------------------------------------------------------------------------

phase_preflight() {
  log "phase: preflight ok"
  push '{
    "title": "Setting up Domo",
    "kicker": "Setting up · step 1 of 7",
    "subtitle": "This page checks each step off on its own — follow the highlighted step.",
    "steps": [
      { "id": "preflight", "label": "Check tooling", "status": "ok",
        "detail": "bun, jq, expect, claude 2.1.80 — all present" }
    ],
    "verification": null,
    "done": false
  }'
}

phase_scaffold() {
  log "phase: scaffold ok"
  push '{
    "title": "Setting up Domo",
    "kicker": "Setting up · step 2 of 7",
    "subtitle": "Laying down the Domo project so the commands below are real.",
    "steps": [
      { "id": "preflight", "label": "Check tooling", "status": "ok",
        "detail": "bun, jq, expect, claude 2.1.80 — all present" },
      { "id": "scaffold", "label": "Scaffold the Domo project", "status": "ok",
        "detail": "Cloned seed-domo and ran domo setup" }
    ],
    "verification": null,
    "done": false
  }'
}

phase_connector() {
  log "phase: connector ok"
  push '{
    "title": "Setting up Domo",
    "kicker": "Setting up · step 3 of 7",
    "subtitle": "Confirming the Google Calendar connector is enabled.",
    "steps": [
      { "id": "preflight", "label": "Check tooling", "status": "ok",
        "detail": "bun, jq, expect, claude 2.1.80 — all present" },
      { "id": "scaffold", "label": "Scaffold the Domo project", "status": "ok",
        "detail": "Cloned seed-domo and ran domo setup" },
      { "id": "connector", "label": "Enable Google Calendar connector", "status": "ok",
        "detail": "Calendar tools detected" }
    ],
    "verification": null,
    "done": false
  }'
}

phase_login_waiting() {
  log "phase: login waiting (terminal command)"
  push '{
    "title": "Setting up Domo",
    "kicker": "Setting up · step 4 of 7",
    "subtitle": "One thing for you to do — sign in to Claude, then watch it check off.",
    "steps": [
      { "id": "preflight", "label": "Check tooling", "status": "ok",
        "detail": "bun, jq, expect, claude 2.1.80 — all present" },
      { "id": "scaffold", "label": "Scaffold the Domo project", "status": "ok",
        "detail": "Cloned seed-domo and ran domo setup" },
      { "id": "connector", "label": "Enable Google Calendar connector", "status": "ok",
        "detail": "Calendar tools detected" },
      { "id": "login", "label": "Sign in to Claude", "status": "waiting",
        "detail": "Waiting for you to sign in…",
        "action": {
          "instruction": "Opens Domo'\''s folder in Claude; type /login when it loads, then come back here.",
          "where": "terminal",
          "command": "~/domo/seed-domo/ref/domo login"
        } }
    ],
    "verification": null,
    "done": false
  }'
}

phase_chat_prompt() {
  log "phase: chat prompt"
  push '{
    "title": "Setting up Domo",
    "kicker": "Setting up · step 5 of 7",
    "subtitle": "The chat-shape question stays in the terminal.",
    "steps": [
      { "id": "preflight", "label": "Check tooling", "status": "ok",
        "detail": "bun, jq, expect, claude 2.1.80 — all present" },
      { "id": "scaffold", "label": "Scaffold the Domo project", "status": "ok",
        "detail": "Cloned seed-domo and ran domo setup" },
      { "id": "connector", "label": "Enable Google Calendar connector", "status": "ok",
        "detail": "Calendar tools detected" },
      { "id": "login", "label": "Sign in to Claude", "status": "ok",
        "detail": "Signed in on your subscription" },
      { "id": "chat", "label": "Choose your chat", "status": "active",
        "detail": "Answer the one terminal question" }
    ],
    "verification": null,
    "done": false
  }'
}

# phase_verify_panel <name> <code> <number> [verified]
# Pushes a verification-panel state showing one self + one member. If the 4th
# arg is "verified", the member row is flipped to verified.
phase_verify_panel() {
  local name="$1" code="$2" number="$3" verified="${4:-pending}"
  local member_status canResend subtitle msg
  if [ "$verified" = "verified" ]; then
    member_status="verified"; canResend=false
    subtitle="Everyone is verified — wrapping up."
    msg="2 of 2 verified."
  else
    member_status="pending"; canResend=true
    subtitle="Have each person text their code to the chat line to verify."
    msg="1 of 2 verified — waiting on the rest."
  fi
  log "phase: verify panel ($name -> $member_status)"
  push '{
    "title": "Setting up Domo",
    "kicker": "Setting up · step 6 of 7",
    "subtitle": "'"$subtitle"'",
    "steps": [
      { "id": "login", "label": "Sign in to Claude", "status": "ok" },
      { "id": "chat", "label": "Choose your chat", "status": "ok",
        "detail": "Household group" },
      { "id": "verify", "label": "Verify each member", "status": "'"$([ "$member_status" = verified ] && echo ok || echo active)"'",
        "detail": "Text the code from each person'\''s phone" }
    ],
    "verification": [
      { "name": "Patrick", "isSelf": true, "status": "verified" },
      { "name": "'"$name"'", "isSelf": false, "status": "'"$member_status"'",
        "code": "'"$code"'", "number": "'"$number"'", "canResend": '"$canResend"' }
    ],
    "message": "'"$msg"'",
    "done": false
  }'
}

phase_persona_defaults() {
  log "phase: persona defaults"
  push '{
    "title": "Setting up Domo",
    "kicker": "Setting up · step 7 of 7",
    "subtitle": "Applying sensible defaults before building.",
    "steps": [
      { "id": "verify", "label": "Verify each member", "status": "ok",
        "detail": "Everyone verified" },
      { "id": "persona", "label": "Persona & trust", "status": "active",
        "detail": "Defaults selected by the installer" }
    ],
    "verification": null,
    "done": false
  }'
}

phase_building() {
  log "phase: building"
  push '{
    "title": "Setting up Domo",
    "kicker": "Almost there",
    "subtitle": "Building your Domo — this takes a moment.",
    "steps": [
      { "id": "persona", "label": "Persona & trust", "status": "ok",
        "detail": "Saved" },
      { "id": "building", "label": "Building your Domo", "status": "active",
        "detail": "Authoring and starting Domo…" }
    ],
    "verification": null,
    "done": false
  }'
}

phase_done() {
  log "phase: done"
  push '{
    "title": "Domo is live",
    "kicker": "All set",
    "subtitle": "Your Domo is running. Text it to start talking.",
    "steps": [
      { "id": "building", "label": "Building your Domo", "status": "ok",
        "detail": "Domo authored and started" },
      { "id": "live", "label": "Domo is live", "status": "ok",
        "detail": "Text '"$SIM_LINE_NUMBER"' to talk to it" }
    ],
    "verification": null,
    "message": "Domo is live — text '"$SIM_LINE_NUMBER"' to talk to it.",
    "done": true
  }'
}

# ---------------------------------------------------------------------------
# Part 2 — real Plow verification leg (only when DOMO_PLOW_TOKEN is set).
# Returns 0 if it ran a live verification (so the caller skips the simulated
# panel); nonzero if it was skipped or failed (caller falls back to simulated).
# ---------------------------------------------------------------------------

# plow_api <method> <path> [json-body]: curl helper that attaches the Bearer
# token from the ENVIRONMENT. The token is never echoed.
plow_api() {
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -sS -X "$method" "${PLOW_API}${path}" \
      -H "Authorization: Bearer ${DOMO_PLOW_TOKEN}" \
      -H 'Content-Type: application/json' \
      --data-binary "$body"
  else
    curl -sS -X "$method" "${PLOW_API}${path}" \
      -H "Authorization: Bearer ${DOMO_PLOW_TOKEN}"
  fi
}

real_plow_leg() {
  _installer_need curl
  _installer_need jq

  log "live Plow leg: API=$PLOW_API TWIN=$PLOW_TWIN"

  # 1. List lines; pick ln_p1 and its provider_key (the number members text).
  local lines line_id line_number
  lines="$(plow_api GET /v1/lines)" || { log "GET /v1/lines failed"; return 1; }
  line_id="$(printf '%s' "$lines" | jq -r '.data[]? | select(.uid=="ln_p1") | .uid' | head -n1)"
  line_number="$(printf '%s' "$lines" | jq -r '.data[]? | select(.uid=="ln_p1") | .provider_key' | head -n1)"
  if [ -z "$line_id" ] || [ "$line_id" = "null" ]; then
    log "could not find line ln_p1 in /v1/lines"
    return 1
  fi
  log "using line $line_id ($line_number)"

  # 2. Create a chat: one agent (carries the line), one member "Sarah".
  local chat chat_uid chat_line code
  chat="$(plow_api POST /v1/chats '{
    "participants": [
      { "type": "agent",  "line_id": "'"$line_id"'" },
      { "type": "member", "display_name": "Sarah" }
    ]
  }')" || { log "POST /v1/chats failed"; return 1; }
  chat_uid="$(printf '%s' "$chat" | jq -r '.uid // empty')"
  # The chat's OWN line provider_key is what the member texts (to_phone).
  chat_line="$(printf '%s' "$chat" | jq -r '.provider_key // empty')"
  code="$(printf '%s' "$chat" \
    | jq -r '.participants[]? | select(.type=="member") | .verification_code // empty' | head -n1)"
  if [ -z "$chat_uid" ] || [ -z "$code" ]; then
    log "chat create response missing uid or verification_code"
    return 1
  fi
  [ -n "$chat_line" ] || chat_line="$line_number"
  log "created chat $chat_uid; Sarah code $code; texts to $chat_line"

  # 3. Push a verification panel showing Sarah pending with her code + the number.
  phase_verify_panel "Sarah" "$code" "$chat_line" pending

  # 4. Simulate Sarah's phone: POST inbound to the TWIN (NOT the API).
  #    to_phone = the chat's own line provider_key; remote_phone is any number
  #    outside the reserved +15550000001..+15550000006 range.
  local inbound_status
  inbound_status="$(curl -sS -o /dev/null -w '%{http_code}' \
    -X POST "${PLOW_TWIN}/ui/inbound" \
    -H 'Content-Type: application/json' \
    --data-binary '{
      "to_phone": "'"$chat_line"'",
      "remote_phone": "+15557654321",
      "text": "'"$code"'"
    }')" || { log "TWIN /ui/inbound POST failed"; _plow_cleanup "$chat_uid"; return 1; }
  log "TWIN /ui/inbound (Sarah texts her code) -> HTTP $inbound_status"

  # 5. Poll the chat until status == active (~5s).
  local waited=0 status detail
  while [ "$waited" -lt 5 ]; do
    detail="$(plow_api GET "/v1/chats/${chat_uid}")" || true
    status="$(printf '%s' "$detail" | jq -r '.status // empty' 2>/dev/null || true)"
    if [ "$status" = "active" ]; then
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  if [ "$status" = "active" ]; then
    log "chat $chat_uid is now active — Sarah verified"
    phase_verify_panel "Sarah" "$code" "$chat_line" verified
  else
    log "chat did not reach active within 5s (status='${status:-?}'); showing pending"
    phase_verify_panel "Sarah" "$code" "$chat_line" pending
  fi

  # 6. Soft-delete the chat to leave no test residue.
  _plow_cleanup "$chat_uid"
  return 0
}

_plow_cleanup() {
  local uid="$1"
  [ -n "$uid" ] || return 0
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' \
    -X DELETE "${PLOW_API}/v1/chats/${uid}" \
    -H "Authorization: Bearer ${DOMO_PLOW_TOKEN}" 2>/dev/null || echo "?")"
  log "DELETE /v1/chats/${uid} (soft-delete) -> HTTP $code"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  # Fail clearly if the server isn't up.
  installer_url >/dev/null || {
    log "installer server-info not found — start ref/installer/server.ts first"
    exit 1
  }
  log "driving installer at $(installer_url)"

  phase_preflight
  phase_scaffold
  phase_connector
  phase_login_waiting
  phase_chat_prompt

  # Verification: real leg if a token is present, else simulated.
  if [ -n "${DOMO_PLOW_TOKEN:-}" ]; then
    log "DOMO_PLOW_TOKEN present — running the live Plow verification leg"
    if ! real_plow_leg; then
      log "live Plow leg failed — falling back to a simulated verified panel"
      phase_verify_panel "Sarah" "VERIFY-EF34GH" "$SIM_LINE_NUMBER" verified
    fi
  else
    log "DOMO_PLOW_TOKEN unset — SKIPPING the live Plow leg; pushing simulated panels"
    phase_verify_panel "Sarah" "VERIFY-EF34GH" "$SIM_LINE_NUMBER" pending
    phase_verify_panel "Sarah" "VERIFY-EF34GH" "$SIM_LINE_NUMBER" verified
  fi

  phase_persona_defaults
  phase_building
  phase_done

  log "done — installer driven through every phase"
}

main "$@"
