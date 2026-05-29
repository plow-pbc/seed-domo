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
# MCP tools surface to PreToolUse as:  mcp__<server-name>__<tool-name>
#
# The Google Calendar tools come from the **claude.ai account CONNECTOR** (not a
# locally-added MCP server), so <server-name> is an Anthropic-assigned **UUID**
# that is account-specific, unpredictable, and CHANGES if the connector is
# reconnected (Claude Code issues #22599/#22276). We therefore CANNOT hardcode the
# full tool_name. Instead we match the **leaf** (the <tool-name> after the last
# `__`) against a read-only allowlist and IGNORE the server/UUID segment.
#
# Security note: leaf-matching is intentionally prefix-agnostic — ANY MCP server
# exposing a tool whose leaf is one of these would be allowed. That is acceptable
# here ONLY because this is an isolated instance whose connected surface is just
# Calendar + the fakechat channel, and because every WRITE leaf and every non-MCP
# tool (Bash/Write/Edit/WebFetch/Read/…) is still default-denied. To harden later,
# pin the discovered UUID by switching a read entry to a full mcp__<uuid>__<leaf>.
#
# TODO-VERIFY (once): the exact leaf names aren't documented for connectors. Run a
# calendar query in the session; if it's denied, THIS hook's stderr prints the
# literal tool_name (see deny()), so you can read the real leaf and adjust below.

# Read-only Google Calendar tool LEAVES (server/UUID segment ignored).
READ_LEAVES=(
  list_calendars   # list the user's calendars (read)
  list_events      # list events in a window   (read)
  get_event        # fetch one event by id      (read)
  suggest_time     # propose free slots — read-only per PLAN.md §9
)
# NEVER add WRITE leaves: create_event, update_event, delete_event, respond_to_event.

# Channel reply tool(s). The channel is a LOCAL plugin (server segment = the plugin
# name, NOT a UUID), so match exactly. TODO-VERIFY the literal name via the deny log.
REPLY_TOOLS=(
  "mcp__fakechat__reply"                   # send Domo's reply back to the chat
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

# ALLOW path: documented stdout JSON + exit 0. hookEventName MUST be "PreToolUse".
allow() {
  printf '%s\n' \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"on Domo allowlist"}}'
  exit 0
}

# -----------------------------------------------------------------------------
# Membership test.
# (1) Non-MCP tools never start with `mcp__` — Bash, Write, Edit, Read, WebFetch,
#     Glob, Grep, Task, … all default-deny here outright.
# (2) Channel reply tool(s): exact match (server segment is a stable plugin name).
# (3) Calendar read tools: leaf match, ignoring the <server>/<UUID> segment.
# Everything else (write leaves, unknown leaves, other connectors) falls through
# to deny.
# -----------------------------------------------------------------------------
case "$TOOL_NAME" in
  mcp__*) : ;;                                   # an MCP tool — evaluate below
  *) deny "$TOOL_NAME is not an MCP tool" ;;
esac

# (2) exact-match reply tool(s)
for allowed in "${REPLY_TOOLS[@]}"; do
  [ "$TOOL_NAME" = "$allowed" ] && allow
done

# (3) leaf-match read-only calendar tools. Strip "mcp__", then take everything
# after the first "__" of the remainder => the tool leaf (server/UUID discarded).
rest="${TOOL_NAME#mcp__}"     # <server>__<leaf>
leaf="${rest#*__}"            # <leaf>
for allowed in "${READ_LEAVES[@]}"; do
  [ "$leaf" = "$allowed" ] && allow
done

# DEFAULT-DENY fall-through. Hard block, no prompt. The printed tool_name is the
# discovery aid for confirming connector leaf names (see the ALLOW comment block).
deny "$TOOL_NAME is not on the allowlist (leaf='$leaf')"
