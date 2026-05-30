# Domo — operator guide

A channels-only, host-raw, subscription-billed household assistant on a Mac.

Domo runs as **ONE persistent `claude --channels` session** in Claude Code **auto
mode** (classifier-gated permissions, [`PLAN.md`](./PLAN.md) §8). The `domo` CLI
bootstraps that session, runs the Plow Chat activation handshake, and runs the session
either in the **foreground** (`shell`, for one-time consent/login/debug) or as a
**detached background daemon** (`start`/`stop`/`status`/`logs`). `shell` and `start`
share **one pinned session UUID**, so they are a single continuous conversation.

> **Status:** the real surface is now the **custom `plow-chat` channel** — a Plow Chat
> WebSocket client + REST sender that bridges a real SMS/texting conversation to the
> session. **`fakechat` is demoted to a local test channel** (no Plow activation
> needed). Select with `DOMO_CHANNEL=plow-chat` (default) or `DOMO_CHANNEL=fakechat`.
> No `/loop` briefings yet (deferred per PLAN.md §4.2/§11).

---

## Architecture at a glance

```
the Mac (host-raw, subscription)
└─ ONE persistent session (auto mode):
   claude --channels plugin:plow-chat --plugin-dir channels/plow-chat \
          --permission-mode auto  --session-id <pinned-uuid>   # or --resume on later runs

   INBOUND   plow-chat WSS  message_received  ->  <channel source="plow-chat"> event
   OUTBOUND  reply tool     ->  POST /v1/chats/{uid}/messages  (a real text to the owner)

   Isolation: CLAUDE_CONFIG_DIR=$DOMO_HOME/.claude · own login · own workspace
```

- The **channel** (`channels/plow-chat/server.ts`, bun/TS, mirrors `fakechat`) is a
  **WSS client + REST sender** — there is **no localhost listening server**, so no port
  to bind or conflict with. It reads its Bearer token from a chmod-600 state file whose
  path is passed in `PLOW_CHAT_STATE` (exactly how `fakechat` receives `FAKECHAT_PORT`).
- The **`domo` CLI** owns the lifecycle: dirs, the pinned session UUID, the Plow
  activation handshake, and foreground/background launch.

---

## Prerequisites

- **A Mac.** Host-raw, no Docker, no servers (PLAN.md §2, §7).
- **Claude Code** with `channels` (research preview, **v2.1.80+**) and `auto`
  permission mode. Verifies `--session-id`, `--resume`, `--channels`, `--plugin-dir`,
  `--permission-mode` are present.
- **bun** (the channel runtime; `domo` launches the server via bun exactly like
  `fakechat`). Verified bun 1.2.22.
- **A Claude Pro/Max/Team login** (subscription auth — **not** Bedrock/Vertex/Foundry).
- A Google account with a calendar, connected at claude.ai (see setup step A).
- For `plow-chat`: a phone able to text the activation code (see `./domo activate`).

> **Never set `ANTHROPIC_API_KEY`.** Domo must use subscription auth, never a metered
> API key (PLAN.md §6). Every `domo` launch unsets it; `./domo doctor` asserts it.

---

## The isolated paths

Everything Domo touches lives under `$DOMO_HOME`, which **defaults to this git
checkout** (`/Users/plucas/cncorp/seed-domo`) — so the instance is isolated from your
personal Claude Code and its state stays inside the project. `domo` derives the paths
below; export `DOMO_HOME` to relocate (e.g. `~/domo`). `.claude/` and `workspace/` are
gitignored (PLAN.md §7):

| Path | What it is |
|---|---|
| `$DOMO_HOME/.claude` | `CLAUDE_CONFIG_DIR` — **all** Domo state: plugins, channel config, sessions, auth. |
| `$DOMO_HOME/.claude/domo.json` | Domo metadata: the **pinned session UUID** (`session_id`), channel, created. |
| `$DOMO_HOME/.claude/plow-chat/state.json` | **chmod-600** redeemed state `{base_url, token, chat_uid}` (the user-wide Bearer token). |
| `$DOMO_HOME/.claude/plow-chat/activation.json` | Transient pre-token activation secret; deleted on successful redeem. |
| `$DOMO_HOME/.claude/plow-chat/last_seen.json` | High-water mark of forwarded message uids (so a restart doesn't replay history). |
| `$DOMO_HOME/.claude/run/` | Daemon runtime: `domo.log`, `domo.pid`, `domo.sig`. |
| `$DOMO_HOME/workspace` | dedicated workspace; `shell`/`start` `cd` here (scopes local file ops + the session project slug). |
| `$DOMO_HOME/channels/plow-chat` | the custom channel plugin, loaded via `--plugin-dir` (NOT a marketplace install). |

The Bearer token is **user-wide**: chmod 600 on the file, chmod 700 on its parent dir,
gitignored by directory **and** by explicit path. It is never logged, never printed
(`status`/`doctor` print `present`/`missing` only), and never passed on a command line.

> **One leak in the isolation:** the Google Calendar **connector** is
> **account-scoped**, not config-dir-scoped (Claude issue #58453). This instance
> inherits *all* connectors on the account you `/login` with. Config, plugins, sessions,
> and channel config stay isolated; connectors don't. Keep the account's connected
> surface minimal (PLAN.md §7, §8).

---

## One-time setup

### `./domo setup`

Idempotent bootstrap:
- exports `CLAUDE_CONFIG_DIR=$DOMO_HOME/.claude`,
- `mkdir -p` the isolated config dir, workspace, `.claude/run`, and `.claude/plow-chat`
  (chmod 700),
- **generates and persists the pinned session UUID** in `.claude/domo.json` if absent
  (`uuidgen`, lowercased) — `shell` and `start` both read it so they're one session,
- for `plow-chat`: verifies the channel dir is loadable (`.claude-plugin/plugin.json`
  + `.mcp.json` + `server.ts` present); it loads via `--plugin-dir`, **no marketplace
  install**,
- for `fakechat`: keeps the legacy marketplace install path
  (`claude plugin marketplace add … && claude plugin install fakechat@… --scope user`),
- prints the remaining interactive steps below.

Then complete the one-time steps:

**A. Connect Google Calendar at the account level (browser, once).**
Go to **[claude.ai/customize/connectors](https://claude.ai/customize/connectors)** →
**Google Calendar** → **Connect**, using the **same Anthropic account** you'll `/login`
with. Connectors are account-scoped, so they auto-load into this isolated session.

**B. Log this instance in (and accept the channels-preview consent).**
```bash
./domo shell        # interactive claude under the isolated config dir
/login              # SAME account that holds the Calendar connector; then exit
```
A fresh config dir does **not** inherit your personal login. The first time `--channels`
is enabled, Claude may ask you to accept the research-preview consent — `shell` is a
real TTY, so accept it once here.

**C. (plow-chat only) Activate the Plow line + chat.**
```bash
./domo activate
```
This runs the Plow handshake in bash + curl (no Python):
1. `POST /v1/auth/activate {name:"Domo", provision_chat:true}` → prints a `display_code`
   and a `send_to` number. **From the phone you want bound to this chat, text exactly**
   `Plow Activate: <display_code>` to `<send_to>`.
2. Polls `POST /v1/auth/activate/redeem` (~every 3s, up to ~5 min) until verified, then
   writes `{base_url, token, chat_uid}` atomically (chmod 600) to
   `.claude/plow-chat/state.json` and deletes the transient activation secret.

Idempotent-ish: if `state.json` already has a token it prints `already activated` and
exits 0; re-run with `--force` to re-activate. The activation secret is passed to curl
via **stdin**, never argv, so it's not visible to other local users via `ps`.

### Auth (token optional)

Auth is the interactive `/login` above. For a fully unattended run, mint a headless
subscription token and `domo` picks it up from the env, `$DOMO_HOME/.env`, or
`$CONFIG_DIR/oauth-token`:

```bash
export CLAUDE_CODE_OAUTH_TOKEN=$(claude setup-token)
```

It's a **subscription** token, not an API key — keep `ANTHROPIC_API_KEY` unset.

---

## Run

```bash
./domo doctor          # read-only preflight (below)
./domo start           # launch the background daemon (one pinned session)
./domo logs            # tail the daemon logfile
./domo status          # resolved config + daemon liveness + channel state
./domo stop            # stop the daemon (tree-kill) + sweep stray channel child
```

### `start` — the background daemon

`start` exports the isolated `CLAUDE_CONFIG_DIR`, resolves auth, unsets
`ANTHROPIC_API_KEY`, sets the per-channel env (`PLOW_CHAT_STATE` or `FAKECHAT_PORT`),
`cd`s to `$DOMO_HOME/workspace`, and launches the **same** argv as `shell`, detached,
logging to `.claude/run/domo.log` with a PID file. It refuses to start if a live daemon
(or an orphaned claude matching this instance) is already running.

**PTY wrapper (verify-at-runtime).** macOS has **no `setsid`**, and an interactive
`claude --channels` may exit on stdin EOF when backgrounded. So `start` gives claude a
controlling PTY via `/usr/bin/script`:

```
nohup script -q -F -e /dev/null  claude … </dev/null >> domo.log 2>&1 &
```

⚠️ **Verify on first real launch** that the session stays alive after the launching
shell exits and that channel events still flow. If `script` mishandles it, set
`DOMO_NO_PTY=1 ./domo start` for a plain background launch, or fall back to a foreground
`./domo shell` under a user-run tmux / launchd `KeepAlive`.

### `stop` — tree-kill

Under the PTY path the recorded PID is the `script` **wrapper**, whose child `claude`
runs in a separate session and is **orphaned** (not reaped) when the wrapper dies. So
`stop` does a **tree-kill**: it TERMs the wrapper, then reaps the real `claude` by a
recorded argv signature scoped to this instance (the absolute `--plugin-dir` path for
plow-chat, or the marketplace channels flag for fakechat), then sweeps the stray channel
server child (`pkill -f channels/plow-chat/server.ts`, or frees `FAKECHAT_PORT`).
Idempotent — no PID file means `not running`, exit 0.

### Session resume — one pinned UUID

The UUID is minted once by `setup` and stored in `.claude/domo.json`. Both `shell` and
`start` resolve the launch flag the same way:
- **first run** (no session jsonl under the workspace project dir yet) → `--session-id <uuid>`
- **subsequent** (jsonl exists) → `--resume <uuid>`

⚠️ **Verify-at-runtime** that `--session-id`/`--resume` **compose with** `--channels`,
and that a `--plugin-dir`-loaded channel is addressable as `plugin:plow-chat`. The flags
each exist in `claude --help`, but their composition can't be checked statically. If
resume doesn't compose with channels, set `DOMO_SESSION_FALLBACK=1` — `domo` then resumes
the **latest jsonl by mtime** under the workspace project dir and persists that id back
to `domo.json`. `--permission-mode auto` is kept in every path.

### `doctor` — preflight

Read-only. Prints the resolved `CLAUDE_CONFIG_DIR`, workspace, channel, session id, and
permission mode; confirms `claude` and `bun` are on PATH; reports auth (token **or**
stored login — either is fine); asserts `ANTHROPIC_API_KEY` is **unset**; for plow-chat
checks the channel dir's 3 packaging files exist and `state.json` is present + chmod 600
+ has a token (or warns `run ./domo activate`). Non-zero exit on any failed assertion.

---

## Exercise it (plow-chat)

1. With `./domo start` running, **text the chat** from the phone you bound during
   `activate`.
2. The message arrives as a `<channel source="plow-chat" chat_id="…" message_id="…">`
   event (the meta also carries the sender's `provider_key` — their phone number — so
   Claude can recognize who's texting).
3. Domo reads your calendar via the connector and **replies as a text** through the
   `reply` tool (`POST /v1/chats/{uid}/messages`).

On reconnect, the channel re-mints a ticket and backfills via
`GET /v1/chats/{uid}/messages`, de-duped by message uid; outbound echoes
(`direction=='outbound'`) are ignored. On a fresh start it establishes a baseline from
the persisted `last_seen.json` so prior history is **not** replayed to Claude.

> **fakechat (local test).** `DOMO_CHANNEL=fakechat ./domo start` runs the localhost UI
> channel (`http://localhost:$FAKECHAT_PORT`, default 8787) with no Plow activation —
> useful for testing the loop and the daemon lifecycle without a token.

---

## Permissions (auto mode) — PLAN.md §8

The session runs `--permission-mode auto`. The classifier sorts each call:

- **allow** (auto-approved, no prompt): read-only ops, the channel `reply`, local file
  ops within the workspace, declared-dependency installs, memory writes. → the normal
  calendar-read + reply loop is here, so it never prompts or hangs.
- **soft_deny** (blocked, overridable): destructive git, prod deploys, irreversible
  local destruction, external-system writes, real-world transactions.
- **hard_deny** (always blocked): data exfiltration, working around the classifier.

> ⚠️ Auto mode is a *generic* guard, not a Domo policy. It does **not** stop calendar
> **writes** on your own calendar, and an always-on agent reading **untrusted inbound
> texts** is a prompt-injection surface (now more real with plow-chat than with the
> local-only fakechat). Add a Domo-specific authorization layer before Domo can act on
> others. The previous default-deny `PreToolUse` hook was removed (it blocked the
> channel `reply`); its design is preserved in PLAN.md §8 for a quick re-add — **do not**
> reintroduce it as the default here.

---

## Verify-at-runtime (can't be checked statically)

The build was validated statically only (`bash -n`, JSON validity, `bun build`/`tsc`
parse, secret-hygiene grep). The live Plow API and `claude` were **not** run (no token
exists; calling would hang). Confirm these on first real launch:

- **Daemon survives backgrounding.** That `script`-wrapped `claude --channels` stays
  alive after the launching shell exits and channel events flow. Escape hatch:
  `DOMO_NO_PTY=1`.
- **Session resume composes with channels.** That `--session-id`/`--resume` work
  alongside `--channels`. Escape hatch: `DOMO_SESSION_FALLBACK=1`.
- **`plugin:plow-chat` resolves** from a `--plugin-dir`-loaded channel. Fallback:
  register the local dir as a one-off local marketplace in setup and address it
  marketplace-qualified.
- **Live Plow loop.** The `activate` curl flow, WSS reconnect/backfill, outbound-echo
  filtering, and the `last_seen` cursor (the messages endpoint exposes no documented
  `after`/`since` param, so de-dup is client-side; the message timestamp field name is
  also unconfirmed).

---

## Files in this repo

- `domo` — the orchestrator CLI: `setup` / `activate` / `shell` / `start` / `stop` /
  `status` / `logs` / `doctor`.
- `run.sh` — the legacy POC launcher (`setup`/`shell`/`start`/`doctor`), superseded by
  `domo`; kept for reference.
- `channels/plow-chat/` — the custom Plow Chat channel plugin (`server.ts`, `.mcp.json`,
  `.claude-plugin/plugin.json`, `package.json`, `.npmrc`, `README.md`).
- `PLAN.md` — the authoritative design.
- `.gitignore` — keeps the isolated `.claude/` (incl. secrets/run dir), `workspace/`,
  `.env`, and channel build artifacts untracked.
