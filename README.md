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

Domo is delivered as a **SEED**: a descriptive knowledge base plus a working
reference implementation that an installing agent uses to stand up a live Domo.
This slice installs one solo household line. The install is a front-loaded
action board: the agent does the API calls and verification, while you only
complete the human-only actions.

`ref/` is the implementation reference: the install dashboard, the `domo` CLI,
the Plow Chat channel, and the four verified piece scripts that the SEED action
runs.

## Install

The standard entry point is the SEED bootstrap:

```bash
curl -fsSL https://raw.githubusercontent.com/plow-pbc/seed/main/install.sh \
  | bash -s -- https://github.com/plow-pbc/seed-domo
```

Already have the SEED skills? Point an agent at this repo:

```bash
git clone https://github.com/plow-pbc/seed-domo && cd seed-domo
```

Then run `/seed-install https://github.com/plow-pbc/seed-domo`, or open the
checkout and ask the agent to install this SEED.

The SEED install action is the install path. It pins the persistent Domo home
outside the checkout:

```bash
export DOMO_HOME="$HOME/.domo"
```

Then the installing agent follows `SEED.md` and runs the four verified pieces in
order:

1. **Login.** `ref/domo-login-piece.sh` creates isolated Claude subscription
   auth under `$DOMO_HOME/.claude`.
2. **Calendar.** `ref/domo-calendar-piece.sh` verifies the claude.ai Google
   Calendar connector for that same account.
3. **Activation.** `ref/domo-activate-piece.sh` performs the Plow text
   activation and writes chmod-600 channel state.
4. **Ready.** `ref/domo-ready-piece.sh` authors the workspace, starts the daemon,
   and sends the first ready text.

The only things you do are the interactive subscription login, the browser
connector toggle, and texting the activation message from the relevant phone.
Tokens and one-time codes stay in chmod-600 gitignored state files and are never
printed as secrets.

## Usage

After install, Domo runs as one pinned, persistent session. The reference CLI is:

```bash
export DOMO_HOME="$HOME/.domo"
ref/domo setup       # isolated dirs, workspace, pinned session UUID
ref/domo activate    # Plow activation; normally run by the installer
ref/domo login       # interactive Claude subscription login in this instance
ref/domo start       # launch the background daemon
ref/domo status      # config + daemon liveness + channel state, no secrets
ref/domo logs        # readable transcript feed
ref/domo doctor      # read-only preflight
ref/domo stop        # stop daemon and scoped channel children
```

`ref/domo logs` renders inbound texts, replies, and tool activity. Add `--raw`
for the underlying PTY capture or `--no-follow` for a one-shot read.

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
