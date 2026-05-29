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

# REPO_ROOT is resolved from this script's own location so the build is portable.
# The hook command path baked into settings.json is the literal absolute path
# (see config/settings.json + the settings_wiring contract).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
REPO_SETTINGS="$REPO_ROOT/config/settings.json"
HOOK_SCRIPT="$REPO_ROOT/hooks/allowlist-guard.sh"

# DOMO_HOME is the isolated Claude home for this instance. For the POC it defaults
# to THIS git checkout, so Domo's config / auth / sessions / plugins are fully
# separate from your personal Claude Code and live entirely inside the project
# (under .claude/, which is gitignored). CONFIG_DIR and WORKSPACE derive from it so
# the isolated paths never drift. Override by exporting DOMO_HOME (e.g. ~/domo)
# without editing this file.
DOMO_HOME="${DOMO_HOME:-$REPO_ROOT}"
CONFIG_DIR="$DOMO_HOME/.claude"
WORKSPACE="$DOMO_HOME/workspace"

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

# Resolve subscription auth (PLAN.md §6/§7). The token is OPTIONAL. Auth resolves
# in this order:
#   1. CLAUDE_CODE_OAUTH_TOKEN (env, then $ENV_FILE, then $TOKEN_FILE) — the
#      headless/cron path ('claude setup-token'). Never hardcoded in the repo.
#   2. Otherwise: the interactive login stored in the isolated config dir (run
#      '/login' once inside ./run.sh shell). This is the POC default.
#   3. If neither exists yet, the interactive session simply prompts to /login.
# This function is NON-FATAL — it never blocks start/shell, because the isolated
# session boots interactively and can authenticate itself.
ensure_auth() {
  if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" && -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    set +u; source "$ENV_FILE"; set -u
  fi
  if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" && -f "$TOKEN_FILE" ]]; then
    CLAUDE_CODE_OAUTH_TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
  fi
  if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
    export CLAUDE_CODE_OAUTH_TOKEN
    log "Auth: using CLAUDE_CODE_OAUTH_TOKEN (headless subscription token)."
  else
    log "Auth: no token set — using the interactive login in $CONFIG_DIR."
    log "      If you haven't logged this instance in yet, run './run.sh shell' and '/login' once."
  fi
  # Guard against accidentally falling back to metered API billing, always.
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

  # Resolve auth (non-fatal). The interactive flows below authenticate the isolated
  # instance via /login if no token is set.
  ensure_auth

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
[domo] These run INSIDE an isolated 'claude' session. Open one with:
[domo]
[domo]      ./run.sh shell        # interactive 'claude' under CLAUDE_CONFIG_DIR=$CONFIG_DIR
[domo]
[domo] (Everything you do there lands in the Domo instance, separate from your
[domo] personal Claude Code.)
[domo]
[domo] 1) Log this instance in (no token needed — a fresh config dir has no login):
[domo]      /login            # browser OAuth; credentials stored in the isolated dir
[domo]
[domo] 2) Google Calendar OAuth (browser flow — no headless registration):
[domo]      /mcp              # complete the google-calendar browser OAuth ONCE
[domo]    Read-only scopes only (calendarlist.readonly / events.readonly / freebusy).
[domo]
[domo] 3) Install the fakechat channel plugin:
[domo]      /plugin marketplace add anthropics/claude-plugins-official
[domo]      /plugin install fakechat@claude-plugins-official
[domo]    TODO-VERIFY: that the install name is literally 'fakechat' (check /plugin).
[domo]    If it differs, update CHANNELS_FLAG in run.sh AND the reply tool_name in
[domo]    hooks/allowlist-guard.sh.
[domo]
[domo] 4) (recommended) Capture the literal tool_names PreToolUse sees:
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
  ensure_auth

  # Refuse to start if setup hasn't run (active settings = the hook wiring).
  [[ -f "$INSTALLED_SETTINGS" ]] || die "active settings not found at $INSTALLED_SETTINGS. Run './run.sh setup' first."
  [[ -d "$WORKSPACE" ]] || die "workspace not found at $WORKSPACE. Run './run.sh setup' first."

  # Scope file tools to the dedicated workspace.
  cd "$WORKSPACE"

  log "Starting persistent session in $WORKSPACE"
  log "Channels: $CHANNELS_FLAG"
  # The ONE persistent session. No 'claude -p'. exec so signals pass through and
  # this script does not linger as a parent. Runs in the foreground TTY so the
  # one-time channels-preview consent (and a /login prompt, if not yet logged in)
  # can be accepted interactively. NEVER add --dangerously-skip-permissions here:
  # that bypasses the PreToolUse allowlist hook (the security spine, PLAN.md §8).
  exec claude --channels "$CHANNELS_FLAG"
}

# ---------------------------------------------------------------------------
# shell — open an interactive 'claude' under the isolated config dir. This is the
# session where you do the one-time /login, /mcp OAuth, and /plugin install.
# Channels are intentionally OFF here so it works before fakechat is installed.
# ---------------------------------------------------------------------------
cmd_shell() {
  export_config_dir
  require_claude
  ensure_auth
  [[ -d "$WORKSPACE" ]] || mkdir -p "$WORKSPACE"
  cd "$WORKSPACE"
  log "Opening interactive Domo session (CLAUDE_CONFIG_DIR=$CONFIG_DIR)."
  log "One-time steps in here: /login, then /mcp (Google OAuth), then /plugin install fakechat."
  exec claude
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

  # Auth is OPTIONAL via token: a token OR a stored interactive login both work.
  # The credentials file is the macOS-file form; on some setups creds live in the
  # Keychain, so absence here is not a failure — just informational.
  if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] || [[ -f "$ENV_FILE" ]] || [[ -f "$TOKEN_FILE" ]]; then
    log "OK   auth: CLAUDE_CODE_OAUTH_TOKEN available (env or token file)"
  elif [[ -f "$CONFIG_DIR/.credentials.json" ]]; then
    log "OK   auth: interactive login present in $CONFIG_DIR"
  else
    log "INFO auth: no token and no detected stored login — run './run.sh shell' then '/login' once (creds may also be in the Keychain)."
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
  setup    One-time bootstrap: create the isolated config dir ($CONFIG_DIR) +
           workspace ($WORKSPACE), copy config/settings.json into place, add the
           Google Calendar MCP, and print the remaining interactive steps. Idempotent.
  shell    Open an interactive 'claude' under the isolated config dir — where you
           do the one-time /login, /mcp OAuth, and /plugin install fakechat.
  start    Launch the single persistent 'claude --channels $CHANNELS_FLAG' session.
  doctor   Read-only preflight; exits non-zero on any failed assertion.

Environment:
  CLAUDE_CODE_OAUTH_TOKEN  (optional) subscription token from 'claude setup-token'
                           for headless/cron use. May live in $ENV_FILE or
                           $TOKEN_FILE. If unset, auth uses the interactive /login
                           stored in the isolated config dir (the POC default).
  DOMO_HOME                (optional) base dir; default: this git checkout.
EOF
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    setup)  shift; cmd_setup "$@" ;;
    shell)  shift; cmd_shell "$@" ;;
    start)  shift; cmd_start "$@" ;;
    doctor) shift; cmd_doctor "$@" ;;
    ""|-h|--help|help) usage; [[ -z "$cmd" ]] && exit 1 || exit 0 ;;
    *) usage; die "unknown command: $cmd" ;;
  esac
}

main "$@"
