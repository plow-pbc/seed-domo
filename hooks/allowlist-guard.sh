#!/usr/bin/env bash
# =============================================================================
# Domo — allowlist-guard.sh  (the security spine)
# -----------------------------------------------------------------------------
# A PreToolUse hook for Claude Code that DEFAULT-DENIES every tool call and
# allows ONLY an explicit, hand-curated allowlist. This is THE most important
# artifact in the POC: it is the boundary that keeps a backgrounded, channel-
# driven Claude session from doing anything beyond reading the calendar and
# replying in the chat channel.
#
# Design + rationale: PLAN.md §8 ("Security model — default-deny allowlist").
#
# -----------------------------------------------------------------------------
# HOOK CONTRACT  (cite: code.claude.com/docs/en/hooks.md)
# -----------------------------------------------------------------------------
# Registered in the ISOLATED settings.json (under CLAUDE_CONFIG_DIR) as:
#   "PreToolUse": [
#     { "matcher": "*", "hooks": [
#         { "type": "command",
#           "command": "/Users/plucas/cncorp/seed-domo/hooks/allowlist-guard.sh",
#           "timeout": 10 } ] } ]
#
# Input  : a single JSON object on STDIN, containing at least:
#            { "tool_name": "...", "tool_input": {...}, "permission_mode": "..." }
# Output : ALLOW path -> JSON on STDOUT + exit 0:
#            {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#             "permissionDecision":"allow","permissionDecisionReason":"..."}}
#          DENY path  -> one-line reason on STDERR + exit 2 (hard block, NO prompt).
#
# WHY ASYMMETRIC (allow=JSON+exit0, deny=stderr+exit2):
#   Per PLAN.md §8 and Claude Code bug #52822 (~v2.1.119), a hook that emits
#   permissionDecision:"deny" JSON may STILL surface the native permission
#   prompt in some versions — and a prompt HANGS a backgrounded channels
#   session. `exit 2` is the documented hard-block that is guaranteed to deny
#   with NO prompt and surfaces the stderr reason to Claude. So:
#       ALLOW  = stdout allow-JSON + exit 0
#       DENY   = stderr reason     + exit 2
#   This hook MUST NEVER emit permissionDecision:"deny" JSON.
#   This hook MUST NEVER exit 1 — exit 1 is a NON-blocking hook error that lets
#   the tool through (fail-open). We always fail CLOSED (deny) on any error.
#
# FAIL-CLOSED guarantees: empty stdin, missing/unparseable tool_name, or a
# missing `jq` all take the DENY path (stderr + exit 2). There is no code path
# that lets an unrecognized tool through.
# =============================================================================

set -u

# -----------------------------------------------------------------------------
# THE ALLOWLIST  (the ONLY thing this session may do)
# -----------------------------------------------------------------------------
# Default-deny: every tool NOT in this array is blocked, including ALL calendar
# WRITE tools (create_event / update_event / delete_event / respond_to_event)
# and every host tool (Bash, Write, Edit, WebFetch, Read, Glob, Grep, Task, …).
# Those are denied by the fall-through, NOT enumerated here — adding to this
# array is the ONLY way to grant a capability. Keep it minimal.
#
# To extend later: add one fully-qualified tool_name string per line below,
# each with a comment explaining why it is safe. Nothing else needs to change.
#
# ----- TODO-VERIFY: MCP tool naming (do this once during `run.sh setup`) ------
# Channels and MCP servers surface tools to PreToolUse as:
#     mcp__<server-name>__<tool-name>
# Two prefixes below are ASSUMPTIONS that MUST be confirmed at setup time by
# reading the literal tool_name from the session/hook log:
#
#   (A) Google Calendar MCP server prefix — assumed "google-calendar",
#       derived from:
#         claude mcp add --transport http google-calendar \
#                 https://calendarmcp.googleapis.com/mcp/v1
#       => prefix "mcp__google-calendar__". If the operator names the server
#       differently, EVERY calendar entry's prefix shifts and calendar reads
#       get silently denied (Claude can't answer "what's on my calendar").
#       Verify via `/mcp` or the hook log, then fix the four lines below.
#
#   (B) fakechat channel `reply` tool — assumed "mcp__fakechat__reply".
#       Channels are MCP servers, so the reply tool should appear as
#       mcp__<plugin>__reply. The plugin install name is assumed `fakechat`
#       (PLAN.md §9). After `/plugin install fakechat@claude-plugins-official`,
#       trigger a reply and read the literal tool_name from the log. If wrong,
#       replies get DENIED — visible immediately (no reply appears in the UI).
#       Fix the single REPLY line below.
# -----------------------------------------------------------------------------
ALLOW=(
  # --- Google Calendar MCP: READ-ONLY tools (prefix TODO-VERIFY: see (A)) ---
  "mcp__google-calendar__list_calendars"   # list the user's calendars (read)
  "mcp__google-calendar__list_events"      # list events in a window   (read)
  "mcp__google-calendar__get_event"        # fetch one event by id      (read)
  "mcp__google-calendar__suggest_time"     # propose free slots — read-only per
                                           #   PLAN.md §9. TODO-VERIFY: if this
                                           #   ever MUTATES, delete this line.

  # --- fakechat channel: reply tool (name TODO-VERIFY: see (B)) -------------
  "mcp__fakechat__reply"                   # send Domo's reply back to the chat

  # !!! NEVER add the calendar WRITE tools here under ANY interpretation: !!!
  #     mcp__google-calendar__create_event
  #     mcp__google-calendar__update_event
  #     mcp__google-calendar__delete_event
  #     mcp__google-calendar__respond_to_event
  # The POC is strictly read-calendar + reply-to-owner (PLAN.md §8, §11, §12).
)

# -----------------------------------------------------------------------------
# DENY helper — the ONLY way this hook blocks. Reason -> stderr, then exit 2.
# Never prints stdout JSON; never exits 1. (See "WHY ASYMMETRIC" above.)
# -----------------------------------------------------------------------------
deny() {
  # $1 = human-readable reason shown to Claude.
  printf 'Domo default-deny: %s\n' "$1" >&2
  exit 2
}

# -----------------------------------------------------------------------------
# FAIL-CLOSED preflight: jq is a hard dependency. No jq => we cannot parse the
# tool_name => we cannot trust the call => DENY.
# -----------------------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  deny "jq not found on PATH; cannot parse PreToolUse input — failing closed"
fi

# -----------------------------------------------------------------------------
# Read the entire PreToolUse JSON object from stdin.
# -----------------------------------------------------------------------------
INPUT="$(cat)"

# Empty/whitespace-only stdin is unparseable input — DENY.
if [ -z "${INPUT//[[:space:]]/}" ]; then
  deny "empty stdin (no PreToolUse payload) — failing closed"
fi

# -----------------------------------------------------------------------------
# Extract tool_name. `jq -e` exits non-zero if the field is null/absent, and
# the whole pipeline fails (set -u not triggered since we capture rc). Any
# parse failure, null, or empty string => DENY.
# -----------------------------------------------------------------------------
TOOL_NAME="$(printf '%s' "$INPUT" | jq -re 'if (.tool_name|type)=="string" then .tool_name else empty end' 2>/dev/null)"
JQ_RC=$?

if [ "$JQ_RC" -ne 0 ] || [ -z "$TOOL_NAME" ]; then
  deny "could not parse a tool_name from PreToolUse input — failing closed"
fi

# -----------------------------------------------------------------------------
# Allowlist membership test (exact string match).
# -----------------------------------------------------------------------------
for allowed in "${ALLOW[@]}"; do
  if [ "$TOOL_NAME" = "$allowed" ]; then
    # ALLOW path: documented stdout JSON + exit 0.
    # hookEventName MUST be exactly "PreToolUse".
    printf '%s\n' \
      '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"on Domo allowlist"}}'
    exit 0
  fi
done

# -----------------------------------------------------------------------------
# DEFAULT-DENY fall-through: anything not explicitly allowed above is blocked.
# This is where Bash, Write, Edit, WebFetch, Read, and the calendar WRITE tools
# all land. Hard block, no prompt.
# -----------------------------------------------------------------------------
deny "$TOOL_NAME is not on the allowlist"
