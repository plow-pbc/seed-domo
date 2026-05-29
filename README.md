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
`CLAUDE_CONFIG_DIR=$DOMO_HOME/.claude` with a dedicated OAuth token and workspace
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

---

## One-time interactive setup (cannot be headless)

These steps require a browser and/or interactive `claude` slash commands. Do them
once; afterward the listener + hook run unattended (PLAN.md §10).

### 1. Get a subscription token

```bash
export CLAUDE_CODE_OAUTH_TOKEN=$(claude setup-token)
```

A fresh `CLAUDE_CONFIG_DIR` does **not** inherit your personal login, so Domo
needs its own dedicated token on the same account (PLAN.md §7). Persist it so
`run.sh` can read it — `run.sh` looks in the environment, then a gitignored
`$DOMO_HOME/.env` or `$DOMO_HOME/.claude/oauth-token`. If it is unset, `run.sh` prints the
`claude setup-token` instruction and exits non-zero rather than proceed. **Do not
hardcode the token in the repo.**

### 2. Run setup

```bash
./run.sh setup
```

This (idempotent):
- exports `CLAUDE_CONFIG_DIR=$DOMO_HOME/.claude`,
- `mkdir -p $DOMO_HOME/.claude $DOMO_HOME/workspace`,
- `chmod +x` the hook,
- **copies** `config/settings.json` → `$DOMO_HOME/.claude/settings.json`,
- runs
  `claude mcp add --transport http google-calendar https://calendarmcp.googleapis.com/mcp/v1`,
- verifies `CLAUDE_CODE_OAUTH_TOKEN` is set (else prints `claude setup-token`
  guidance and exits non-zero),
- then prints the remaining interactive steps below.

### 3. Complete the Google Calendar `/mcp` OAuth browser flow (once)

There is **no headless registration** for the Google connector. In an interactive
Domo session, run:

```
/mcp
```

and complete the Google OAuth browser flow for `google-calendar`. The stored token
lands in the isolated config dir and is reused by the persistent session (PLAN.md
§9). Read-only scopes are expected:
`calendar.calendarlist.readonly`, `calendar.events.readonly`,
`calendar.events.freebusy`.

### 4. Install the fakechat channel plugin (once)

In an interactive Domo session (running under the same `CLAUDE_CONFIG_DIR`):

```
/plugin marketplace add anthropics/claude-plugins-official
/plugin install fakechat@claude-plugins-official
```

Both land in `$DOMO_HOME/.claude`.

---

## Unattended run

```bash
./run.sh start
```

This exports the same `CLAUDE_CONFIG_DIR` + `CLAUDE_CODE_OAUTH_TOKEN`, `cd`s to
`$DOMO_HOME/workspace`, and execs the **one** persistent session:

```
claude --channels plugin:fakechat@claude-plugins-official
```

`start` refuses to launch (clear error) if `$DOMO_HOME/.claude/settings.json` is
missing (setup not run) or if the token is unset.

### Preflight (recommended)

```bash
./run.sh doctor
```

Read-only. Prints the resolved `CLAUDE_CONFIG_DIR`; asserts `settings.json` exists
at the config dir and that its registered hook command path exists and is
executable; confirms `jq` is on PATH; confirms `CLAUDE_CODE_OAUTH_TOKEN` is set and
`ANTHROPIC_API_KEY` is **unset**; echoes the active allowlist. Exits non-zero on
any failed assertion.

---

## Exercise it

1. With `./run.sh start` running, open the fakechat UI at
   **http://localhost:8787** (PLAN.md §9).
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

- **Allow** (stdout JSON + `exit 0`) only for the explicit allowlist:
  - `mcp__google-calendar__list_calendars`
  - `mcp__google-calendar__list_events`
  - `mcp__google-calendar__get_event`
  - `mcp__google-calendar__suggest_time` *(read-only — see verify note)*
  - `mcp__fakechat__reply`
- **Deny** everything else (stderr + `exit 2`, the guaranteed no-prompt
  hard-block per bug #52822). This includes `Bash`, `Write`, `Edit`, `WebFetch`,
  `Read`, `Glob`, `Grep`, `Task`, and — most importantly — the calendar **write**
  tools, which are **NEVER** allowed:
  - `mcp__google-calendar__create_event`
  - `mcp__google-calendar__update_event`
  - `mcp__google-calendar__delete_event`
  - `mcp__google-calendar__respond_to_event`
- **Fail-closed:** empty stdin, missing/unparseable `tool_name`, or missing `jq`
  → deny. The hook never emits `permissionDecision:deny` JSON and never exits 1.

To smoke-test the spine: ask Domo to do something off-allowlist (e.g. "run `ls`"
or "create an event") and confirm it is **blocked with no prompt**, while the
calendar read + reply path works.

---

## Verify at build time

The following were **unverified at build time**. The hook keeps the allowlist as an
explicit, clearly-commented array so each is a one-line fix. Check these once during
the interactive setup:

- **fakechat `reply` tool name.** Assumed `mcp__fakechat__reply` (channels are MCP
  servers; tools surface as `mcp__<server>__<tool>`). After install, trigger a reply
  and read the session/hook log for the literal `tool_name`. If wrong, replies are
  silently denied (no reply appears in the UI). Fix the one channel-reply line in the
  hook's ALLOW array.
- **Google Calendar MCP server prefix.** Assumed `mcp__google-calendar__` from the
  server name `google-calendar` in the `mcp add` command. If you named the server
  differently, the whole prefix shifts and calendar reads are silently denied. Confirm
  via `/mcp` or hook logs; fix all five calendar lines (grouped under a PREFIX comment).
- **Plugin install name.** Assumed `fakechat@claude-plugins-official` (PLAN.md §9).
  Confirm via `/plugin` listing. If different, fix the `--channels` flag in
  `run.sh start` **and** re-verify the resulting reply tool name.
- **`allow` may still prompt (bug #52822, ~v2.1.119).** Mitigated by the asymmetric
  strategy (allow = stdout-JSON + exit 0; deny = exit 2). Verify on your installed
  version that allowlisted tools do **not** raise a prompt. If they do, you are on a
  buggy version — flag it. We deliberately never use `permissionDecision:deny` JSON.
- **`suggest_time` read-only classification.** Included in ALLOW as read-only
  (PLAN.md §9), but flagged. If it turns out to mutate, drop it from ALLOW (one line).
  `create_event` / `update_event` / `delete_event` / `respond_to_event` are **NEVER**
  allowed under any interpretation.
- **Google Calendar MCP endpoint recency.** Use
  `https://calendarmcp.googleapis.com/mcp/v1` exactly; re-confirm at build. The OAuth
  `/mcp` browser flow must be done once interactively (no headless registration); the
  token is then reused by the persistent session.

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
