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

Domo is delivered as a **SEED**: a descriptive knowledge base that an installing
agent uses to generate and verify a live Domo. This checkout ships product prose
and one structural verifier, not a committed runtime. The install is a
front-loaded action board: the agent generates the runtime into a baked home,
does the API calls and verification, while you only complete the human-only
actions.

`ref/` intentionally contains only `verify.sh`, the structural SEED conformance
checker.

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

The SEED install action is the install path. It resolves the persistent Domo
home outside the checkout, defaulting to `$HOME/.domo`, and bakes that absolute
path into all generated files. The generated runtime must not read `DOMO_HOME`.

The installing agent follows `SEED.md` and generates the install steps in order:

1. **Login.** Create isolated Claude subscription auth under `<HOME>/.claude`.
2. **Calendar.** Verify the claude.ai Google Calendar connector for that same
   account.
3. **Activation.** Perform the Plow text activation and write chmod-600 channel
   state.
4. **Ready.** Author the workspace, start the daemon, and send the first ready
   text.

The only things you do are the interactive subscription login, the browser
connector toggle, and texting the activation message from the relevant phone.
Tokens and one-time codes stay in chmod-600 gitignored state files and are never
printed as secrets.

## Usage

After install, Domo runs as one pinned, persistent session. The generated
operator CLI lives at `<HOME>/bin/domo` and uses baked absolute paths for verbs
such as `start`, `stop`, `status`, `logs`, `doctor`, and `reset`.

## Security Posture

- Domo uses Claude subscription auth. `ANTHROPIC_API_KEY` and
  `CLAUDE_CODE_OAUTH_TOKEN` must stay unset on generated launch paths.
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
