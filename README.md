# Domo

A de-Plowed, agent-first household assistant that lives on your Mac, runs on your
Claude subscription, reads your texts, reasons, acts, and texts back.

## Purpose

**Domo** is a personal household assistant that runs as **one persistent
`claude --channels` session** on a Mac, billed against your **Claude
subscription** rather than a metered API key. A real Plow Chat conversation is
wired to that session, so you talk to Domo by text. Domo receives a message,
uses Claude Code and account-level tools such as Google Calendar, then replies
back into the same texting thread.

Domo is delivered as a **SEED**: a descriptive knowledge base plus generated
runtime artifacts that an installing agent uses to stand up a live Domo. This
slice installs a solo or group household chat. The install is a front-loaded
action board: the agent does the API calls and verification, while you only
complete the human-only actions.

`ref/` currently holds the remaining monolith implementation reference while the
repo is being converted into sub-SEEDs. Converted slices live under `seeds/` and
instruct the installing agent to generate their runtime into the baked Domo
home.

## Install

The standard entry point is `/seed-install`, which audits the cloned tree before
running the install action:

```bash
/seed-install https://github.com/plow-pbc/seed-domo
```

Already have the SEED skills? Point an agent at this repo:

```bash
git clone https://github.com/plow-pbc/seed-domo && cd seed-domo
```

Then run `/seed-install .`, or open the checkout and ask the agent to install
this SEED.

The SEED install action is the install path. It pins the persistent Domo home
outside the checkout:

```bash
export DOMO_HOME="$HOME/.domo"
```

Then the installing agent follows `SEED.md`, installs converted sub-SEEDs first,
and runs the generated helpers in order:

1. **Login.** `seeds/claude-instance/SEED.md` generates isolated Claude
   subscription auth helpers under `$DOMO_HOME/runtime/claude-instance` and
   verifies `$DOMO_HOME/.claude`.
2. **Calendar.** `seeds/calendar-connector/SEED.md` generates connector probe
   helpers under `$DOMO_HOME/runtime/calendar-connector` and verifies the
   claude.ai Google Calendar connector for that same account.
3. **Activation.** `seeds/plow-activation/SEED.md` generates Plow text
   activation helpers under `$DOMO_HOME/runtime/plow-activation`, supports solo
   or group mode, and writes chmod-600 channel state.
4. **Runtime.** `seeds/domo-runtime/SEED.md` generates
   `$DOMO_HOME/bin/domo` and runtime helpers under
   `$DOMO_HOME/runtime/domo-runtime`; it authors the workspace, starts the
   pinned-session daemon, gates readiness on host channel registration, and
   sends the first ready text.

The only things you do are the interactive subscription login, the browser
connector toggle, and texting the activation message from the relevant phone.
Tokens and one-time codes stay in chmod-600 gitignored state files and are never
printed as secrets.

## Usage

After install, Domo runs as one pinned, persistent session. The generated CLI is:

```bash
$HOME/.domo/bin/domo ready   # launch the daemon and send the first ready text
$HOME/.domo/bin/domo start   # launch the background daemon
$HOME/.domo/bin/domo status  # config + daemon liveness + channel state, no secrets
$HOME/.domo/bin/domo logs    # readable transcript feed
$HOME/.domo/bin/domo doctor  # read-only preflight
$HOME/.domo/bin/domo stop    # stop daemon and scoped channel children
$HOME/.domo/bin/domo reset   # delegated cleanup/logout plus guarded local removal
```

`$HOME/.domo/bin/domo logs` renders inbound texts, replies, and tool activity.
Add `--raw` for the underlying PTY capture or `--no-follow` for a one-shot read.

## Security Posture

- Domo uses Claude subscription auth. `ANTHROPIC_API_KEY` must stay unset, and
  `ref/domo` unsets it on launch paths.
- The Plow Bearer token is user-wide. It is stored chmod 600 under the isolated
  `.claude/plow-chat` state dir, gitignored, never logged, never printed, and
  never committed.
- Activation secrets are passed through stdin or files, not command arguments.
- The daemon uses `--permission-mode auto`, not `bypassPermissions` by default.
- The Google Calendar connector is account-scoped in claude.ai. Keep that
  account's connected surface minimal.

## License

[MIT](LICENSE) © 2026 plow-pbc. Use, modify, and redistribute freely with
attribution.
