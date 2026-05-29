# Domo POC — operator guide

A channels-only, host-raw, subscription-billed household assistant on a Mac.

This is the **POC** described in [`PLAN.md`](./PLAN.md) §10. It proves the whole
Domo loop with the cheapest comms layer (`fakechat`), so that any failure is
unambiguously in **isolation**, **calendar**, or **security** — not in a
half-built channel.

> **Status:** POC. Read-only calendar + reply-to-owner only. No calendar writes,
> no sending to others, no `/loop` briefings yet (deferred per PLAN.md §4.2/§11).

---

## What this POC proves

The loop (PLAN.md §10):

> Spin up an **isolated** Domo Claude → it has Google Calendar (read) via MCP +
> the `fakechat` channel + the **default-deny** PreToolUse hook → type
> *"what's on my calendar today?"* in the fakechat UI → it calls the calendar
> connector → replies in the browser with your events.

The runtime is **ONE persistent session**:

```
claude --channels plugin:fakechat@claude-plugins-official
```

There is no `claude -p` path. The same always-on session would later handle both
interactive chat and scheduled briefings. Everything is isolated under
`CLAUDE_CONFIG_DIR=$DOMO_HOME/.claude` with its own login and workspace
(PLAN.md §7). The security spine is a `PreToolUse` hook that **default-denies**
and allows only Google Calendar **read** tools + the fakechat `reply` tool
(PLAN.md §8).

---

## Prerequisites

- **A Mac.** Host-raw, no Docker, no servers (PLAN.md §2, §7).
- **Claude Code that supports `channels`** — research preview, **v2.1.80+**
  (PLAN.md §4.1). See the [Verify at build time](#verify-at-build-time) note about
  bug #52822 (~v2.1.119) for the `allow`-prompt caveat.
- **A Claude Pro/Max login** (subscription auth, claude.ai or Console — **not**
  Bedrock/Vertex/Foundry). Pro/Max users without an org skip enterprise gating
  (PLAN.md §4.1, §6).
- **`jq` on PATH** — the hook depends on it; it fails closed (deny) if `jq` is
  absent. Install with `brew install jq`.
- A Google account with a calendar (for the read-only connector).

> **Never set `ANTHROPIC_API_KEY`.** Domo must use subscription auth via
> `CLAUDE_CODE_OAUTH_TOKEN`, never a metered API key (PLAN.md §6). `run.sh doctor`
> asserts the API key is unset.

---

## The three isolated paths

Everything Domo touches lives under `$DOMO_HOME`, which **for the POC defaults to
this git checkout** (`/Users/plucas/cncorp/seed-domo`) — so the instance is fully
isolated from your personal Claude Code and its state stays inside the project.
`run.sh` derives the paths below; export `DOMO_HOME` to relocate (e.g. `~/domo`).
`.claude/` and `workspace/` are gitignored:

| Path | What it is |
|---|---|
| `$DOMO_HOME/.claude` | `CLAUDE_CONFIG_DIR` — **all** Domo state: settings, plugins, MCP servers, channel config, sessions, auth. |
| `$DOMO_HOME/.claude/settings.json` | the **active** config — a copy of `config/settings.json` that registers the hook. |
| `$DOMO_HOME/workspace` | dedicated, scoped workspace; `start` runs from here. |

The hook script itself is **not** copied. `config/settings.json` registers the
hook by its **absolute repo path**
`/Users/plucas/cncorp/seed-domo/hooks/allowlist-guard.sh`, and `run.sh setup`
`chmod +x`'s it. `setup` is idempotent — re-running overwrites the copied
`settings.json` so edits to the repo source propagate.

> **One leak in the isolation:** the Google Calendar **connector** is
> **account-scoped**, not config-dir-scoped — there's no per-config-dir opt-out
> (Claude issue #58453). So this instance inherits *all* connectors on the account
> you `/login` with, not just Calendar. Config, plugins, sessions, and channel
> config stay isolated; connectors don't. The default-deny hook is what keeps Domo
> from actually *using* any non-calendar connector.

---

## One-time interactive setup (cannot be headless)

These steps require a browser and/or interactive `claude` slash commands. Do them
once; afterward the listener + hook run unattended (PLAN.md §10).

### 1. Run setup

```bash
./run.sh setup
```

This (idempotent):
- exports `CLAUDE_CONFIG_DIR=$DOMO_HOME/.claude`,
- `mkdir -p $DOMO_HOME/.claude $DOMO_HOME/workspace`,
- `chmod +x` the hook,
- **copies** `config/settings.json` → `$DOMO_HOME/.claude/settings.json`,
- then prints the remaining interactive steps below.

(No `claude mcp add` — calendar comes from the claude.ai account connector in step 2.)

### 2. Connect Google Calendar at the account level (once)

In a browser, go to **[claude.ai/customize/connectors](https://claude.ai/customize/connectors)**
→ **Google Calendar** → **Connect**, using the **same Anthropic account** you'll
`/login` with in step 3. Connectors are **account-scoped**, so once connected they
auto-load into any Claude Code session on that account — including this isolated
instance. No `claude mcp add`, no GCP OAuth client. (Requires a Pro/Max/Team plan;
the first-party `calendarmcp.googleapis.com` MCP is *not* usable from Claude Code —
it fails on dynamic client registration. See PLAN.md §9.)

### 3. Open the isolated session and log in

```bash
./run.sh shell
```

`shell` opens an interactive `claude` under `CLAUDE_CONFIG_DIR=$DOMO_HOME/.claude`
(channels off, so it works before fakechat is installed). A fresh config dir does
**not** inherit your personal login, so authenticate this instance once — with the
**same account that holds the Calendar connector**:

```
/login
```

Credentials are stored **in the isolated dir** and reused by the persistent session
— so no `CLAUDE_CODE_OAUTH_TOKEN` is needed for the POC. The Calendar connector
auto-loads on this login. (A `setup-token` is only worth it later for a fully
unattended/cron tier; see [Auth](#auth-token-optional).)

### 4. Install the fakechat channel plugin (once)

Still inside `./run.sh shell`:

```
/plugin marketplace add anthropics/claude-plugins-official
/plugin install fakechat@claude-plugins-official
```

Both land in `$DOMO_HOME/.claude`. Then exit the shell — you're ready to `start`.

> **Connector tool names.** Connector tools surface to the hook as
> `mcp__<account-UUID>__<tool>`, where the UUID is account-specific and
> unpredictable. The allowlist hook therefore matches the **read-tool leaf**
> (`list_events`, `get_event`, …) and ignores the UUID. If a calendar query is
> denied, the hook's stderr prints the literal `tool_name` — read the leaf and
> confirm it's in `READ_LEAVES` in `hooks/allowlist-guard.sh`.

> **Channels preview consent.** The first time the persistent session enables
> `--channels`, Claude may ask you to accept the research-preview consent. Because
> `start` runs in a foreground TTY, accept it once interactively. This is **not**
> the same as `--dangerously-skip-permissions` — Domo never passes that flag, since
> it would bypass the `PreToolUse` allowlist hook (the security spine, PLAN.md §8).

### Auth (token optional)

For the POC, auth is the interactive `/login` above (stored in `$DOMO_HOME/.claude`).
If you later want a fully unattended/cron run with no interactive login, mint a
headless subscription token and let `run.sh` pick it up from the env or a
gitignored file:

```bash
export CLAUDE_CODE_OAUTH_TOKEN=$(claude setup-token)   # or persist in $DOMO_HOME/.env
```

It's a **subscription** token, not an API key — keep `ANTHROPIC_API_KEY` unset.
**Never hardcode it in the repo.**

---

## Unattended run

```bash
./run.sh start
```

This exports the isolated `CLAUDE_CONFIG_DIR` (and a token if one is set), `cd`s to
`$DOMO_HOME/workspace`, and execs the **one** persistent session in the foreground:

```
claude --channels plugin:fakechat@claude-plugins-official
```

`start` refuses to launch (clear error) if `$DOMO_HOME/.claude/settings.json` is
missing (setup not run). It does **not** require a token — if none is set, it uses
the interactive login stored during `./run.sh shell`.

### Preflight (recommended)

```bash
./run.sh doctor
```

Read-only. Prints the resolved `CLAUDE_CONFIG_DIR`; asserts `settings.json` exists
at the config dir and that its registered hook command path exists and is
executable; confirms `jq` is on PATH; reports auth (token **or** stored interactive
login — either is fine); asserts `ANTHROPIC_API_KEY` is **unset**; echoes the active
allowlist (and flags any write-capable entry). Exits non-zero on any failed assertion.

---

## Exercise it

1. With `./run.sh start` running, open the fakechat UI at
   **http://localhost:8787** (PLAN.md §9). `start` prints the exact URL.
   The port is configurable via `FAKECHAT_PORT` if 8787 is taken:
   `FAKECHAT_PORT=8799 ./run.sh start` → http://localhost:8799.
2. Type: **"what's on my calendar today?"**
3. Domo reads your calendar via the Google MCP connector and **replies in the
   browser** with your events.

Inbound arrives to the session as a `<channel source="fakechat">` event; the reply
shows in the browser.

---

## Acceptance criteria (checklist — PLAN.md §10)

- [ ] Inbound text arrives as a `<channel source="fakechat">` event.
- [ ] Claude calls **only** allowlisted tools (Google Calendar read tools +
      the fakechat `reply`) — the hook denies anything else, with **no
      prompt/hang**.
- [ ] The reply lands in the fakechat UI with the **correct** events.

### The security spine (PLAN.md §8)

The `PreToolUse` hook (`matcher: "*"`, `timeout: 10`) is **default-deny**:

- **Allow** (stdout JSON + `exit 0`) only for:
  - the calendar **read leaves** — `list_calendars`, `list_events`, `get_event`,
    `suggest_time` — matched **prefix-agnostically** (any `mcp__<server-or-UUID>__<leaf>`),
    because the connector's server segment is an unpredictable account UUID;
  - the channel reply tool `mcp__fakechat__reply` (exact match — stable plugin name).
- **Deny** everything else (stderr + `exit 2`, the guaranteed no-prompt
  hard-block per bug #52822). This includes every non-MCP tool (`Bash`, `Write`,
  `Edit`, `WebFetch`, `Read`, `Glob`, `Grep`, `Task`), every **other** account
  connector's tools, and — most importantly — the calendar **write** leaves, which
  are **NEVER** allowed: `create_event`, `update_event`, `delete_event`,
  `respond_to_event`.
- **Fail-closed:** empty stdin, missing/unparseable `tool_name`, or missing `jq`
  → deny. The hook never emits `permissionDecision:deny` JSON and never exits 1.
- Because connectors are **account-scoped** (no per-config-dir opt-out), this hook
  is also what stops Domo from using any *other* connector on your account.

To smoke-test the spine: ask Domo to do something off-allowlist (e.g. "run `ls`"
or "create an event") and confirm it is **blocked with no prompt**, while the
calendar read + reply path works.

---

## Verify at build time

The following were **unverified at build time**. The hook keeps the allowlist as an
explicit, clearly-commented array so each is a one-line fix. Check these once during
the interactive setup:

- **Calendar tool leaves.** The connector's read-tool leaf names
  (`list_calendars` / `list_events` / `get_event` / `suggest_time`) aren't documented
  for connectors. Ask "what's on my calendar today?"; if denied, the hook's stderr
  prints the literal `tool_name` (e.g. `mcp__<uuid>__list_events`) — read the leaf and
  confirm it's in `READ_LEAVES`. Wrong leaf → calendar reads silently denied.
- **fakechat `reply` tool name.** Assumed `mcp__fakechat__reply` (matched exactly).
  After install, trigger a reply and read the log for the literal `tool_name`. If
  wrong, replies are silently denied (no reply in the UI). Fix `REPLY_TOOLS` in the hook.
- **Plugin install name.** Assumed `fakechat@claude-plugins-official` (PLAN.md §9).
  Confirm via `/plugin`. If different, fix `CHANNELS_FLAG` in `run.sh` **and** re-verify
  the reply tool name.
- **`allow` may still prompt (bug #52822, ~v2.1.119).** Mitigated by the asymmetric
  strategy (allow = stdout-JSON + exit 0; deny = exit 2). Verify on your installed
  version that allowlisted tools do **not** raise a prompt. If they do, you are on a
  buggy version — flag it. We deliberately never use `permissionDecision:deny` JSON.
- **`suggest_time` read-only classification.** Allowed as a read leaf (PLAN.md §9).
  If it turns out to mutate, drop it from `READ_LEAVES`. The write leaves
  (`create_event` / `update_event` / `delete_event` / `respond_to_event`) are **NEVER**
  allowed under any interpretation.
- **Leaf-match is prefix-agnostic.** Acceptable because the isolated instance's only
  connected surface is Calendar + fakechat. To harden, pin the discovered UUID by
  switching a `READ_LEAVES` entry to a full `mcp__<uuid>__<leaf>` exact match.

---

## Known-open (no build action — PLAN.md §6/§11)

- **Persistent-session billing pool.** Whether a backgrounded persistent
  `claude --channels` session draws the interactive subscription pool vs the
  June-15-2026 Agent SDK credit pool is unconfirmed. Subscription either way (not
  metered API on a claude.ai login).
- **Agent SDK on subscription.** Docs gave conflicting signals; unresolved. The
  persistent `--channels` session sidesteps the question — we don't use the SDK
  streaming-input path.
- **`/loop` composition with channel event-handling.** Out of scope for this POC;
  `start` only runs the persistent channels session. External `launchd`-into-channel
  is the fallback briefing trigger (PLAN.md §4.2).
- **Channels = research preview.** The `--channels` flag/protocol may change.

---

## Files in this repo

- `run.sh` — `setup` / `start` / `doctor` subcommands.
- `hooks/allowlist-guard.sh` — the default-deny `PreToolUse` hook (the security spine).
- `config/settings.json` — repo source of truth; copied to
  `$DOMO_HOME/.claude/settings.json` by `run.sh setup`, registering the hook by its
  absolute repo path.
- `PLAN.md` — the authoritative design.
