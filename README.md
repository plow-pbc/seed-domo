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
The install asks one setup question up front: solo, or group, and if group, who
is in the household. That answer changes the activation path and the authored
workspace. The rest of the install is a front-loaded action board: the agent does
the API calls and verification, while you only complete the human-only actions.

`ref/` is the implementation reference: the install dashboard, the `domo` CLI,
the Plow Chat channel, and the bootstrap driver that ties them together.

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

The SEED install action invokes the live bootstrap driver:

```bash
ref/installer/domo-install.sh
```

That driver is the install, not a demo path. It runs the phased flow:

1. **Bootstrap fast.** Check `bun`, `jq`, `expect`, and Claude Code >= 2.1.80;
   run `ref/domo setup`; launch the local dashboard.
2. **Front-load inputs.** Ask the one terminal question: solo or group, and if
   group, member names. The dashboard simultaneously shows the exact human-only
   actions: run `domo login` in a new terminal, enable Google Calendar at
   `https://claude.ai/customize/connectors`, and text the Plow verification
   code(s) when shown.
3. **Preflight and build while away.** The installer owns
   `$DOMO_HOME/install-state.json`, retries the login/calendar preflight until it
   can verify both from inside the Domo session, then authors the workspace,
   wires Plow Chat, and starts the daemon.
4. **Ready.** The dashboard reaches done when Domo is live:
   `Domo is live - text <number> to talk to it.`

The only things you do are the interactive subscription login, the browser
connector toggle, and texting verification codes from the relevant phone(s).
Tokens and one-time codes stay in chmod-600 gitignored state files and are never
printed as secrets.

## Usage

After install, Domo runs as one pinned, persistent session. The reference CLI is:

```bash
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
