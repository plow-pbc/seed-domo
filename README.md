# Domo POC — operator guide

A channels-only, host-raw, subscription-billed household assistant on a Mac.

This is the **POC** described in [`PLAN.md`](./PLAN.md) §10. It proves the whole
Domo loop with the cheapest comms layer (`fakechat`), so any failure is unambiguously
in **isolation** or **calendar** — not in a half-built channel.

> **Status:** POC. Single-user, reading the owner's own calendar and replying to the
> owner via fakechat. Runs in Claude Code's **auto mode** (classifier-gated
> permissions, PLAN.md §8) — no custom allowlist. No `/loop` briefings yet
> (deferred per PLAN.md §4.2/§11).

---

## What this POC proves

The loop (PLAN.md §10):

> Spin up an **isolated** Domo Claude → Google Calendar via the claude.ai **connector**
> + the `fakechat` channel, in **auto mode** → type *"what's on my calendar today?"* in
> the fakechat UI → it calls the calendar connector → replies in the browser with your
> events.

The runtime is **ONE persistent session**:

```
claude --channels plugin:fakechat@claude-plugins-official --permission-mode auto
```

There is no `claude -p` path. The same always-on session would later handle both
interactive chat and scheduled briefings. Everything is isolated under
`CLAUDE_CONFIG_DIR=$DOMO_HOME/.claude` with its own login and workspace (PLAN.md §7).

**Permissions:** the session runs in Claude Code's **`auto` mode** — a classifier
auto-approves safe calls (read-only ops, the channel `reply`, local workspace ops),
soft-blocks risky writes, and hard-blocks data exfiltration (PLAN.md §8). There is no
Domo-specific allowlist; that's a follow-up before Domo can act on others.

---

## Prerequisites

- **A Mac.** Host-raw, no Docker, no servers (PLAN.md §2, §7).
- **Claude Code** with `channels` (research preview, **v2.1.80+**) and `auto`
  permission mode (v2.1.x). Tested on v2.1.157.
- **A Claude Pro/Max/Team login** (subscription auth, claude.ai or Console — **not**
  Bedrock/Vertex/Foundry). Connectors and channels require this (PLAN.md §4.1, §6, §9).
- A Google account with a calendar, connected at claude.ai (see step 2).

> **Never set `ANTHROPIC_API_KEY`.** Domo must use subscription auth, never a metered
> API key (PLAN.md §6). `run.sh doctor` asserts the API key is unset.

---

## The isolated paths

Everything Domo touches lives under `$DOMO_HOME`, which **for the POC defaults to this
git checkout** (`/Users/plucas/cncorp/seed-domo`) — so the instance is isolated from
your personal Claude Code and its state stays inside the project. `run.sh` derives the
paths below; export `DOMO_HOME` to relocate (e.g. `~/domo`). `.claude/` and
`workspace/` are gitignored:

| Path | What it is |
|---|---|
| `$DOMO_HOME/.claude` | `CLAUDE_CONFIG_DIR` — **all** Domo state: plugins, channel config, sessions, auth. |
| `$DOMO_HOME/workspace` | dedicated workspace; `start` runs from here (scopes local file ops). |

> **One leak in the isolation:** the Google Calendar **connector** is
> **account-scoped**, not config-dir-scoped — there's no per-config-dir opt-out
> (Claude issue #58453). So this instance inherits *all* connectors on the account you
> `/login` with, not just Calendar. Config, plugins, sessions, and channel config stay
> isolated; connectors don't. Auto mode's classifier soft-blocks risky writes to other
> connectors but doesn't Domo-scope them — keep the account's connected surface minimal
> (PLAN.md §7, §8).

---

## One-time setup

### 1. Run setup

```bash
./run.sh setup
```

This (idempotent):
- exports `CLAUDE_CONFIG_DIR=$DOMO_HOME/.claude`,
- `mkdir -p $DOMO_HOME/.claude $DOMO_HOME/workspace`,
- **installs the fakechat plugin headlessly** —
  `claude plugin marketplace add anthropics/claude-plugins-official` then
  `claude plugin install fakechat@claude-plugins-official --scope user`
  (user scope = this isolated config dir; no `/plugin` TUI),
- prints the remaining interactive steps below.

(No `claude mcp add` — calendar comes from the claude.ai account connector in step 2.)

### 2. Connect Google Calendar at the account level (once)

In a browser, go to **[claude.ai/customize/connectors](https://claude.ai/customize/connectors)**
→ **Google Calendar** → **Connect**, using the **same Anthropic account** you'll
`/login` with in step 3. Connectors are **account-scoped**, so once connected they
auto-load into any Claude Code session on that account — including this isolated
instance. No `claude mcp add`, no GCP OAuth client. (The first-party
`calendarmcp.googleapis.com` MCP is *not* usable from Claude Code — it fails on dynamic
client registration; see PLAN.md §9.)

### 3. Log the instance in

```bash
./run.sh shell      # interactive `claude` under the isolated config dir (channels off)
/login              # SAME account that holds the Calendar connector; then exit
```

A fresh config dir does **not** inherit your personal login. Credentials are stored in
the isolated dir and reused by the persistent session — so no `CLAUDE_CODE_OAUTH_TOKEN`
is needed for the POC. The Calendar connector auto-loads on this login.

> **fakechat is already installed by `setup`.** If that step warned (e.g. it needed
> login first), finish it here: `/plugin install fakechat@claude-plugins-official` →
> choose **user scope**.

> **Channels preview consent.** The first time the persistent session enables
> `--channels`, Claude may ask you to accept the research-preview consent. Because
> `start` runs in a foreground TTY, accept it once interactively.

### Auth (token optional)

For the POC, auth is the interactive `/login` above. For a fully unattended/cron run
with no interactive login, mint a headless subscription token and `run.sh` picks it up
from the env or a gitignored file:

```bash
export CLAUDE_CODE_OAUTH_TOKEN=$(claude setup-token)   # or persist in $DOMO_HOME/.env
```

It's a **subscription** token, not an API key — keep `ANTHROPIC_API_KEY` unset. Never
hardcode it in the repo.

---

## Run

```bash
./run.sh doctor                      # preflight (below)
FAKECHAT_PORT=8799 ./run.sh start    # the one persistent session; prints the UI URL
```

`start` exports the isolated `CLAUDE_CONFIG_DIR`, `cd`s to `$DOMO_HOME/workspace`, and
execs the **one** persistent session in the foreground:

```
claude --channels plugin:fakechat@claude-plugins-official --permission-mode auto
```

It refuses to launch only if the workspace is missing (run `setup` first). It does
**not** require a token — without one it uses the interactive login from `shell`.
`FAKECHAT_PORT` overrides the default UI port (8787).

### Preflight — `doctor`

Read-only. Prints the resolved `CLAUDE_CONFIG_DIR` and workspace; confirms `claude` is
on PATH; reports auth (token **or** stored interactive login — either is fine); asserts
`ANTHROPIC_API_KEY` is **unset**; echoes the channels flag and permission mode. Exits
non-zero on any failed assertion.

---

## Exercise it

1. With `./run.sh start` running, open the fakechat UI at the URL `start` printed
   (`http://localhost:$FAKECHAT_PORT`, default 8787).
2. Type: **"what's on my calendar today?"**
3. Domo reads your calendar via the connector and **replies in the browser** with your
   events.

Inbound arrives as a `<channel source="fakechat">` event; the reply shows in the
browser.

### Acceptance criteria (PLAN.md §10)

- [ ] Inbound text arrives as a `<channel source="fakechat">` event.
- [ ] Claude reads the calendar via the connector
      (`mcp__claude_ai_Google_Calendar__*`), auto-approved by auto mode.
- [ ] The reply lands in the fakechat UI with the **correct** events — no prompt/hang.

---

## Permissions (auto mode) — PLAN.md §8

The session runs `--permission-mode auto`. The classifier (inspect via
`claude auto-mode defaults`) sorts each call:

- **allow** (auto-approved, no prompt): read-only ops, the channel `reply`, local file
  ops within the workspace, declared-dependency installs, memory writes. → the normal
  calendar-read + reply loop is here, so it never prompts or hangs.
- **soft_deny** (blocked, overridable): destructive git, prod deploys, irreversible
  local destruction, external-system writes, real-world transactions.
- **hard_deny** (always blocked): data exfiltration, working around the classifier.

> ⚠️ Auto mode is a *generic* guard, not a Domo policy. It does **not** stop calendar
> **writes** on your own calendar, and an always-on agent reading untrusted inbound is
> still a prompt-injection surface. Fine for this single-user POC; add a Domo-specific
> authorization layer before Domo can act on others. The previous default-deny
> `PreToolUse` hook was removed (it blocked the channel `reply`); its design + the
> observed live tool names are preserved in PLAN.md §8 for a quick re-add.

---

## Known-open (no build action — PLAN.md §6/§11)

- **Persistent-session billing pool.** Whether a backgrounded persistent
  `claude --channels` session draws the interactive subscription pool vs the
  June-15-2026 Agent SDK credit pool is unconfirmed. Subscription either way.
- **Agent SDK on subscription.** Conflicting docs; the persistent `--channels` session
  sidesteps it (we don't use the SDK streaming-input path).
- **`/loop` composition with channel event-handling.** Out of scope for this POC;
  external `launchd`-into-channel is the fallback briefing trigger (PLAN.md §4.2).
- **Channels = research preview.** The `--channels` flag/protocol may change.

---

## Files in this repo

- `run.sh` — `setup` / `shell` / `start` / `doctor` subcommands.
- `PLAN.md` — the authoritative design.
- `.gitignore` — keeps the isolated `.claude/`, `workspace/`, and `.env` untracked.
