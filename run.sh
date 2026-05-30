#!/usr/bin/env bash
#
# run.sh — Domo orchestrator (POC)
#
# Domo is a channels-only, host-raw, subscription-billed household assistant.
# This script bootstraps and runs the ONE persistent `claude --channels` session
# that is the whole runtime. There is no `claude -p` path.
#
# POC permission posture: the session runs in `--permission-mode auto` — Claude Code's
# classifier-gated "auto mode" (the shift+tab mode in the UI). No custom PreToolUse
# allowlist: auto mode auto-approves SAFE calls (read-only ops, the channel reply,
# local workspace ops), soft-blocks risky writes, and hard-blocks data exfiltration.
# See PLAN.md §8. (`bypassPermissions` = allow-everything-no-checks is available via
# DOMO_PERMISSION_MODE but is NOT the default.)
#
# See PLAN.md §4 (channels + runtime), §7 (isolation), §9 (Google Calendar), §10 (POC).
#
# Subcommands:
#   setup    one-time bootstrap (config dir, workspace, fakechat plugin install)
#   shell    interactive 'claude' under the isolated config dir (for /login)
#   start    launch the single persistent channels session (auto mode)
#   doctor   read-only preflight
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Source-of-truth paths
# ---------------------------------------------------------------------------

# REPO_ROOT is resolved from this script's own location so the build is portable.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

# DOMO_HOME is the isolated Claude home for this instance. For the POC it defaults
# to THIS git checkout, so Domo's config / auth / sessions / plugins are fully
# separate from your personal Claude Code and live entirely inside the project
# (under .claude/, which is gitignored). Override by exporting DOMO_HOME (e.g. ~/domo).
DOMO_HOME="${DOMO_HOME:-$REPO_ROOT}"
CONFIG_DIR="$DOMO_HOME/.claude"
WORKSPACE="$DOMO_HOME/workspace"

# Optional gitignored file/key that exports CLAUDE_CODE_OAUTH_TOKEN. Sourced if
# present so the operator can avoid re-exporting the token in every shell.
ENV_FILE="$DOMO_HOME/.env"
TOKEN_FILE="$CONFIG_DIR/oauth-token"

# Google Calendar comes from the claude.ai ACCOUNT CONNECTOR (PLAN.md §9), not a
# locally-added MCP server: connect it once at claude.ai/customize/connectors, then
# /login this instance with the SAME account and the connector auto-loads. No
# `claude mcp add`. (Observed tool surface: mcp__claude_ai_Google_Calendar__<tool>.)

# Channel plugin + marketplace. `setup` installs these headlessly via
# `claude plugin marketplace add` + `claude plugin install … --scope user`.
MARKETPLACE_SRC="anthropics/claude-plugins-official"   # GitHub repo for the marketplace
PLUGIN_SPEC="fakechat@claude-plugins-official"         # <plugin>@<marketplace-name>
CHANNELS_FLAG="plugin:fakechat@claude-plugins-official" # space-separated for more channels

# fakechat serves its localhost UI on FAKECHAT_PORT (default 8787; confirmed in the
# plugin source `Number(process.env.FAKECHAT_PORT ?? 8787)`). Override if 8787 is taken:
#   FAKECHAT_PORT=8799 ./run.sh start
FAKECHAT_PORT="${FAKECHAT_PORT:-8787}"

# Permission posture for the persistent session. Default `auto` = Claude Code's
# classifier-gated auto mode: SAFE calls (read-only + the channel reply + local
# workspace ops) are auto-approved with no prompt, so the normal calendar-read+reply
# loop never hangs; risky writes are soft-blocked and exfiltration hard-blocked.
# Override via DOMO_PERMISSION_MODE — e.g. `bypassPermissions` (allow EVERYTHING, no
# checks) or `default` (prompts on most calls, which can hang a backgrounded session).
PERMISSION_MODE="${DOMO_PERMISSION_MODE:-auto}"

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
log()  { printf '[domo] %s\n' "$*" >&2; }
warn() { printf '[domo] WARNING: %s\n' "$*" >&2; }
die()  { printf '[domo] ERROR: %s\n' "$*" >&2; exit 1; }

# Export the isolated config dir — scopes plugins / connectors / sessions / auth to
# the Domo instance. MUST be exported in every subcommand that launches `claude`.
export_config_dir() {
  export CLAUDE_CONFIG_DIR="$CONFIG_DIR"
  log "CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR"
}

# Resolve subscription auth (PLAN.md §6/§7). The token is OPTIONAL:
#   1. CLAUDE_CODE_OAUTH_TOKEN (env, then $ENV_FILE, then $TOKEN_FILE) — headless path.
#   2. Otherwise the interactive login stored in the isolated config dir (/login).
# NON-FATAL: never blocks start/shell; the session can authenticate itself.
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
  # Keep subscription auth; never silently fall back to metered API billing.
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    warn "ANTHROPIC_API_KEY is set; unsetting it so subscription auth is used."
    unset ANTHROPIC_API_KEY
  fi
}

require_claude() {
  command -v claude >/dev/null 2>&1 || die "the 'claude' CLI is not on PATH. Install Claude Code first."
}

# fakechat's bun server can outlive the claude session (orphaned to launchd) and keep
# holding FAKECHAT_PORT, which makes the NEXT start show 'fakechat: failed'. Before
# launching, free the port if a stale fakechat (`bun … server.ts`) holds it; warn (but
# don't kill) if some OTHER process holds it (e.g. OrbStack/Wrangler on 8787).
free_fakechat_port() {
  command -v lsof >/dev/null 2>&1 || return 0
  local pids pid cmd
  pids="$(lsof -nP -tiTCP:"$FAKECHAT_PORT" -sTCP:LISTEN 2>/dev/null || true)"
  for pid in $pids; do
    cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
    if printf '%s' "$cmd" | grep -q 'server\.ts'; then
      warn "Freeing port $FAKECHAT_PORT: killing stale fakechat server (pid $pid)."
      kill "$pid" 2>/dev/null || true
      sleep 1
    else
      warn "Port $FAKECHAT_PORT is held by a non-fakechat process (pid $pid: ${cmd%% *})."
      warn "fakechat will fail to bind — pick a free port: FAKECHAT_PORT=<n> ./run.sh start"
    fi
  done
}

# ---------------------------------------------------------------------------
# setup — one-time bootstrap (idempotent)
# ---------------------------------------------------------------------------
cmd_setup() {
  export_config_dir
  require_claude
  ensure_auth

  log "Creating isolated config dir and workspace..."
  mkdir -p "$CONFIG_DIR" "$WORKSPACE"

  # Install the fakechat channel plugin headlessly (no /plugin TUI). --scope user
  # installs into THIS isolated config dir. Best-effort + idempotent. stdin from
  # /dev/null so an unexpected confirmation prompt fails fast instead of hanging.
  log "Adding marketplace '$MARKETPLACE_SRC' (user scope)..."
  claude plugin marketplace add "$MARKETPLACE_SRC" </dev/null >/dev/null 2>&1 \
    || warn "marketplace add returned non-zero (may already exist). Continuing."
  log "Installing plugin '$PLUGIN_SPEC' (user scope)..."
  if claude plugin install "$PLUGIN_SPEC" --scope user </dev/null; then
    log "fakechat installed."
  else
    warn "plugin install returned non-zero (may already be installed, or needs /login first)."
    warn "If needed, finish it in './run.sh shell':  /plugin install $PLUGIN_SPEC"
  fi

  cat >&2 <<EOF

[domo] ============================================================
[domo] REMAINING ONE-TIME INTERACTIVE STEPS
[domo] ============================================================
[domo]
[domo] A) Connect Google Calendar ONCE at the ACCOUNT level (in a browser):
[domo]      https://claude.ai/customize/connectors  -> Google Calendar -> Connect
[domo]    Use the SAME Anthropic account you'll /login below. Account-scoped, so it
[domo]    then auto-loads into this isolated instance (no 'claude mcp add').
[domo]
[domo] B) Log this instance in:
[domo]      ./run.sh shell    # interactive 'claude' under CLAUDE_CONFIG_DIR=$CONFIG_DIR
[domo]      /login            # SAME account that holds the Calendar connector; then exit
[domo]    (A fresh config dir has no login; no token needed. fakechat is already
[domo]    installed above — if that step warned, run /plugin install $PLUGIN_SPEC here.)
[domo]
[domo] Then run:  ./run.sh doctor   and   ./run.sh start
[domo] (start runs --permission-mode $PERMISSION_MODE — classifier-gated auto mode.)
[domo] ============================================================
EOF

  log "Setup complete (interactive login + calendar connect still required)."
}

# ---------------------------------------------------------------------------
# start — the whole runtime: one persistent channels session, auto mode
# ---------------------------------------------------------------------------
cmd_start() {
  export_config_dir
  require_claude
  ensure_auth

  [[ -d "$WORKSPACE" ]] || die "workspace not found at $WORKSPACE. Run './run.sh setup' first."
  cd "$WORKSPACE"

  # fakechat reads FAKECHAT_PORT from the environment; export it so the demo UI
  # binds where we expect and we can print the right URL. Clear any stale fakechat
  # server still holding the port from a previous run.
  export FAKECHAT_PORT
  free_fakechat_port
  log "Starting persistent session in $WORKSPACE"
  log "Channels: $CHANNELS_FLAG"
  log "Permission mode: $PERMISSION_MODE (classifier-gated; safe calls auto-approved)"
  log "fakechat UI: http://localhost:$FAKECHAT_PORT"
  # The ONE persistent session. No 'claude -p'. exec so signals pass through. Runs
  # in the foreground TTY so the one-time channels-preview consent (and a /login
  # prompt, if needed) can be accepted interactively.
  exec claude --channels "$CHANNELS_FLAG" --permission-mode "$PERMISSION_MODE"
}

# ---------------------------------------------------------------------------
# shell — interactive 'claude' under the isolated config dir. Primary use: the
# one-time /login. (fakechat is installed by `setup`; calendar is the claude.ai
# account connector, connected in a browser.) Channels are OFF here.
# ---------------------------------------------------------------------------
cmd_shell() {
  export_config_dir
  require_claude
  ensure_auth
  [[ -d "$WORKSPACE" ]] || mkdir -p "$WORKSPACE"
  cd "$WORKSPACE"
  log "Opening interactive Domo session (CLAUDE_CONFIG_DIR=$CONFIG_DIR)."
  log "One-time step in here: /login (same account as the Calendar connector). Then exit."
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

  if [[ -d "$WORKSPACE" ]]; then
    log "OK   workspace present: $WORKSPACE"
  else
    warn "MISS workspace absent: $WORKSPACE (run './run.sh setup')"; ok=1
  fi

  if command -v claude >/dev/null 2>&1; then
    log "OK   'claude' CLI on PATH"
  else
    warn "MISS 'claude' CLI not on PATH"; ok=1
  fi

  # Auth: a token OR a stored interactive login both work. On macOS, creds may live
  # in the Keychain, so absence of the file form is informational, not a failure.
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

  log "Channels flag:   $CHANNELS_FLAG"
  log "Permission mode: $PERMISSION_MODE (classifier-gated auto mode)"

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
           workspace ($WORKSPACE), install the fakechat plugin (user scope), and
           print the remaining interactive steps. Idempotent.
  shell    Open an interactive 'claude' under the isolated config dir — for the
           one-time /login (fakechat is installed by 'setup').
  start    Launch the single persistent 'claude --channels $CHANNELS_FLAG' session
           in classifier-gated auto mode (--permission-mode $PERMISSION_MODE).
  doctor   Read-only preflight; exits non-zero on any failed assertion.

Environment:
  CLAUDE_CODE_OAUTH_TOKEN  (optional) subscription token from 'claude setup-token'
                           for headless/cron use. May live in $ENV_FILE or
                           $TOKEN_FILE. If unset, auth uses the interactive /login
                           stored in the isolated config dir (the POC default).
  DOMO_HOME                (optional) base dir; default: this git checkout.
  FAKECHAT_PORT            (optional) fakechat UI port; default 8787.
  DOMO_PERMISSION_MODE     (optional) permission mode; default auto (classifier-gated).
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
