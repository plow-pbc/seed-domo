#!/usr/bin/env bash
#
# run.sh — Domo orchestrator (POC)
#
# Domo is a channels-only, host-raw, subscription-billed household assistant.
# This script bootstraps and runs the ONE persistent `claude --channels` session
# that is the whole runtime. There is no `claude -p` path.
#
# See PLAN.md §4 (channels + runtime), §7 (isolation), §8 (security model),
# §9 (Google Calendar MCP), §10 (POC plan).
#
# Subcommands:
#   setup    one-time interactive bootstrap (config dir, workspace, settings,
#            Google Calendar MCP, plugin marketplace + fakechat install)
#   start    launch the single persistent channels session
#   doctor   read-only preflight: assert the environment is wired correctly
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Source-of-truth paths (single source -> the three absolute paths stay in sync)
# ---------------------------------------------------------------------------

# DOMO_HOME is an internal convenience var only (default ~/domo). CONFIG_DIR and
# WORKSPACE are derived from it so the isolated paths never drift.
DOMO_HOME="${DOMO_HOME:-$HOME/domo}"
CONFIG_DIR="$DOMO_HOME/.claude"
WORKSPACE="$DOMO_HOME/workspace"

# The hook script and the repo's settings source live in this git checkout.
# REPO_ROOT is resolved from this script's own location so the build is portable,
# but the hook command path baked into settings.json is the literal absolute path
# (see config/settings.json + the settings_wiring contract).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
REPO_SETTINGS="$REPO_ROOT/config/settings.json"
HOOK_SCRIPT="$REPO_ROOT/hooks/allowlist-guard.sh"

# The ACTIVE config that the persistent session reads. `setup` COPIES the repo
# settings here (copy, not symlink: a symlink into a git checkout is brittle and
# muddies the isolation story). The hook script itself is NOT copied — settings
# references it by absolute repo path.
INSTALLED_SETTINGS="$CONFIG_DIR/settings.json"

# Optional gitignored file that exports CLAUDE_CODE_OAUTH_TOKEN (and nothing else
# secret should live in the repo). Sourced if present so the operator can avoid
# re-exporting the token in every shell.
ENV_FILE="$DOMO_HOME/.env"
TOKEN_FILE="$CONFIG_DIR/oauth-token"

# Google Calendar MCP (PLAN.md §9). Server name -> tool prefix mcp__google-calendar__.
GOOGLE_MCP_NAME="google-calendar"
GOOGLE_MCP_URL="https://calendarmcp.googleapis.com/mcp/v1"

# Channels flag for the persistent session (PLAN.md §4.2, §9).
# TODO-VERIFY: that the plugin install name is literally `fakechat` and the
# marketplace id is `claude-plugins-official` (confirm via `/plugin` at setup).
# Space-separated if more channels are ever added.
CHANNELS_FLAG="plugin:fakechat@claude-plugins-official"

# Active allowlist (mirrors hooks/allowlist-guard.sh). Echoed by `doctor` so the
# operator can eyeball what is permitted without opening the hook.
# TODO-VERIFY at setup: the literal tool_names as seen by PreToolUse — the
# fakechat `reply` tool name and the google-calendar server prefix.
ALLOWLIST=(
  "mcp__google-calendar__list_calendars"
  "mcp__google-calendar__list_events"
  "mcp__google-calendar__get_event"
  "mcp__google-calendar__suggest_time"   # read-only per PLAN.md §9; drop if it mutates
  "mcp__fakechat__reply"                  # the channel reply tool — TODO-VERIFY exact name
)

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

log()  { printf '[domo] %s\n' "$*" >&2; }
warn() { printf '[domo] WARNING: %s\n' "$*" >&2; }
die()  { printf '[domo] ERROR: %s\n' "$*" >&2; exit 1; }

# Export the isolated config dir. This is what makes
# config/settings.json -> ~/domo/.claude/settings.json the ACTIVE hook config,
# and what scopes plugins / MCP servers / channel config / sessions / auth to
# the Domo instance. MUST be exported in both setup and start.
export_config_dir() {
  export CLAUDE_CONFIG_DIR="$CONFIG_DIR"
  log "CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR"
}

# Load the subscription OAuth token (PLAN.md §6). Order: existing env var, then
# ~/domo/.env, then ~/domo/.claude/oauth-token. Never hardcoded in the repo.
# If unset after all that, print the `claude setup-token` guidance and exit non-zero.
load_token() {
  if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" && -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    set +u; source "$ENV_FILE"; set -u
  fi
  if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" && -f "$TOKEN_FILE" ]]; then
    CLAUDE_CODE_OAUTH_TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
  fi
  if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
    cat >&2 <<EOF
[domo] ERROR: CLAUDE_CODE_OAUTH_TOKEN is not set.

Domo's isolated config dir does NOT inherit your personal Claude login, so it
needs its own subscription token (same Claude account, dedicated token).

Generate one once:

    claude setup-token

Then make it available to run.sh in any of these ways:

    export CLAUDE_CODE_OAUTH_TOKEN=...                # this shell, or
    echo 'export CLAUDE_CODE_OAUTH_TOKEN=...' >> $ENV_FILE   # persisted (gitignored), or
    printf '%s\n' '<token>' > $TOKEN_FILE             # persisted (gitignored)

This is a subscription token, NOT an API key. Keep ANTHROPIC_API_KEY unset so
subscription auth is used.
EOF
    exit 1
  fi
  export CLAUDE_CODE_OAUTH_TOKEN
  # Guard against accidentally falling back to metered API billing.
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    warn "ANTHROPIC_API_KEY is set; unsetting it so subscription auth is used."
    unset ANTHROPIC_API_KEY
  fi
}

require_claude() {
  command -v claude >/dev/null 2>&1 || die "the 'claude' CLI is not on PATH. Install Claude Code first."
}

# ---------------------------------------------------------------------------
# setup — one-time interactive bootstrap (idempotent)
# ---------------------------------------------------------------------------
cmd_setup() {
  export_config_dir
  require_claude

  # Verify the token early so we fail fast with guidance (the interactive flows
  # below also need an authenticated isolated instance).
  load_token

  log "Creating isolated config dir and workspace..."
  mkdir -p "$CONFIG_DIR" "$WORKSPACE"

  # The hook script must exist and be executable; it is NOT copied — settings.json
  # references it by absolute repo path.
  [[ -f "$HOOK_SCRIPT" ]] || die "hook script missing: $HOOK_SCRIPT (build hooks/allowlist-guard.sh first)"
  chmod +x "$HOOK_SCRIPT"
  log "Marked hook executable: $HOOK_SCRIPT"

  # Materialize the ACTIVE settings by COPYING the repo source. Re-running
  # overwrites it so edits to config/settings.json propagate (idempotent).
  [[ -f "$REPO_SETTINGS" ]] || die "repo settings missing: $REPO_SETTINGS (build config/settings.json first)"
  cp "$REPO_SETTINGS" "$INSTALLED_SETTINGS"
  log "Copied settings: $REPO_SETTINGS -> $INSTALLED_SETTINGS"

  # Add the Google Calendar MCP server (PLAN.md §9). Idempotent-ish: tolerate the
  # "already exists" case so re-running setup doesn't abort.
  log "Adding Google Calendar MCP server '$GOOGLE_MCP_NAME'..."
  if claude mcp add --transport http "$GOOGLE_MCP_NAME" "$GOOGLE_MCP_URL"; then
    log "MCP server added."
  else
    warn "claude mcp add returned non-zero (server may already exist). Continuing."
  fi

  # Plugin marketplace + fakechat install. These are interactive in-session slash
  # commands and cannot be reliably scripted headlessly; print exact instructions.
  cat >&2 <<EOF

[domo] ============================================================
[domo] REMAINING ONE-TIME INTERACTIVE STEPS (cannot be scripted)
[domo] ============================================================
[domo] These run INSIDE an isolated 'claude' session. CLAUDE_CONFIG_DIR is
[domo] already set to $CONFIG_DIR for this shell, so anything you do lands in
[domo] the Domo instance. If you open a new shell, re-export it first:
[domo]
[domo]     export CLAUDE_CONFIG_DIR="$CONFIG_DIR"
[domo]     export CLAUDE_CODE_OAUTH_TOKEN=...   # see 'claude setup-token'
[domo]
[domo] 1) Google Calendar OAuth (browser flow — no headless registration):
[domo]      claude            # or: claude --channels off
[domo]      /mcp              # complete the google-calendar browser OAuth ONCE
[domo]    The stored token is then reused by the persistent headless session.
[domo]    Read-only scopes only (calendarlist.readonly / events.readonly / freebusy).
[domo]
[domo] 2) Install the fakechat channel plugin:
[domo]      claude --channels off
[domo]      /plugin marketplace add anthropics/claude-plugins-official
[domo]      /plugin install fakechat@claude-plugins-official
[domo]    TODO-VERIFY: that the install name is literally 'fakechat' (check /plugin).
[domo]    If it differs, update CHANNELS_FLAG in run.sh AND the reply tool_name in
[domo]    hooks/allowlist-guard.sh.
[domo]
[domo] 3) (recommended) Capture the literal tool_names PreToolUse sees:
[domo]    trigger a calendar read and a fakechat reply once, then inspect the hook
[domo]    log to confirm 'mcp__google-calendar__*' and 'mcp__fakechat__reply'.
[domo]    Adjust the ALLOW array in hooks/allowlist-guard.sh if they differ.
[domo]
[domo] When done, verify with:   ./run.sh doctor
[domo] Then run the assistant:   ./run.sh start
[domo] ============================================================
EOF

  log "Setup complete (interactive steps above still required)."
}

# ---------------------------------------------------------------------------
# start — the whole runtime: one persistent channels session
# ---------------------------------------------------------------------------
cmd_start() {
  export_config_dir
  require_claude
  load_token

  # Refuse to start if setup hasn't run (active settings = the hook wiring).
  [[ -f "$INSTALLED_SETTINGS" ]] || die "active settings not found at $INSTALLED_SETTINGS. Run './run.sh setup' first."
  [[ -d "$WORKSPACE" ]] || die "workspace not found at $WORKSPACE. Run './run.sh setup' first."

  # Scope file tools to the dedicated workspace.
  cd "$WORKSPACE"

  log "Starting persistent session in $WORKSPACE"
  log "Channels: $CHANNELS_FLAG"
  # The ONE persistent session. No 'claude -p'. exec so signals pass through and
  # this script does not linger as a parent.
  exec claude --channels "$CHANNELS_FLAG"
}

# ---------------------------------------------------------------------------
# doctor — read-only preflight; non-zero exit on any failed assertion
# ---------------------------------------------------------------------------
cmd_doctor() {
  export_config_dir
  local ok=0

  log "Resolved CLAUDE_CONFIG_DIR: $CONFIG_DIR"
  log "Resolved workspace:         $WORKSPACE"

  if [[ -f "$INSTALLED_SETTINGS" ]]; then
    log "OK   active settings present: $INSTALLED_SETTINGS"
  else
    warn "MISS active settings absent: $INSTALLED_SETTINGS (run './run.sh setup')"; ok=1
  fi

  # The hook command path registered in settings must exist and be executable.
  # Prefer the path actually recorded in settings.json (truth), falling back to
  # the repo path if we can't parse it.
  local registered_hook=""
  if [[ -f "$INSTALLED_SETTINGS" ]] && command -v jq >/dev/null 2>&1; then
    registered_hook="$(jq -r '.hooks.PreToolUse[]?.hooks[]?.command // empty' "$INSTALLED_SETTINGS" 2>/dev/null | head -n1 || true)"
  fi
  [[ -n "$registered_hook" ]] || registered_hook="$HOOK_SCRIPT"

  if [[ -f "$registered_hook" && -x "$registered_hook" ]]; then
    log "OK   hook present + executable: $registered_hook"
  elif [[ -f "$registered_hook" ]]; then
    warn "MISS hook present but NOT executable: $registered_hook (chmod +x it)"; ok=1
  else
    warn "MISS registered hook not found: $registered_hook"; ok=1
  fi

  if command -v jq >/dev/null 2>&1; then
    log "OK   jq present (hook dependency)"
  else
    warn "MISS jq not on PATH — the hook fails closed (denies all) without it. Install jq."; ok=1
  fi

  if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] || [[ -f "$ENV_FILE" ]] || [[ -f "$TOKEN_FILE" ]]; then
    log "OK   CLAUDE_CODE_OAUTH_TOKEN available (env or token file)"
  else
    warn "MISS CLAUDE_CODE_OAUTH_TOKEN not set and no token file. Run 'claude setup-token'."; ok=1
  fi

  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    warn "WARN ANTHROPIC_API_KEY is set — must be UNSET so subscription auth is used."; ok=1
  else
    log "OK   ANTHROPIC_API_KEY is unset (subscription auth)"
  fi

  if command -v claude >/dev/null 2>&1; then
    log "OK   'claude' CLI on PATH"
  else
    warn "MISS 'claude' CLI not on PATH"; ok=1
  fi

  log "Active allowlist (must match hooks/allowlist-guard.sh):"
  local t
  for t in "${ALLOWLIST[@]}"; do log "       allow: $t"; done

  # Belt-and-suspenders: no allowlist entry may look write-capable. Guards the
  # security spine against a future hand-edit pasting a mutating tool into ALLOW
  # (the 'reply' tool is intentionally allowed and matches none of these verbs).
  local write_verbs='create|insert|update|patch|delete|remove|move|import|quickadd|respond|accept|decline'
  for t in "${ALLOWLIST[@]}"; do
    if printf '%s' "$t" | grep -qiE "$write_verbs"; then
      warn "WARN allowlist entry looks write-capable: '$t' — POC is read + reply only. Remove it."; ok=1
    fi
  done

  log "Channels flag: $CHANNELS_FLAG"

  if [[ "$ok" -eq 0 ]]; then
    log "doctor: all checks passed."
  else
    die "doctor: one or more checks failed (see WARNINGs above)."
  fi
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
usage() {
  cat >&2 <<EOF
Domo orchestrator

Usage: $(basename "$0") <command>

Commands:
  setup    One-time interactive bootstrap: create the isolated config dir
           ($CONFIG_DIR) + workspace ($WORKSPACE), copy config/settings.json into
           place, add the Google Calendar MCP, and print the remaining interactive
           steps (/mcp OAuth, plugin install). Idempotent.
  start    Launch the single persistent 'claude --channels $CHANNELS_FLAG' session.
  doctor   Read-only preflight; exits non-zero on any failed assertion.

Environment:
  CLAUDE_CODE_OAUTH_TOKEN  (required) subscription token from 'claude setup-token'.
                           May instead live in $ENV_FILE or $TOKEN_FILE.
  DOMO_HOME                (optional) base dir; default $HOME/domo.
EOF
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    setup)  shift; cmd_setup "$@" ;;
    start)  shift; cmd_start "$@" ;;
    doctor) shift; cmd_doctor "$@" ;;
    ""|-h|--help|help) usage; [[ -z "$cmd" ]] && exit 1 || exit 0 ;;
    *) usage; die "unknown command: $cmd" ;;
  esac
}

main "$@"
