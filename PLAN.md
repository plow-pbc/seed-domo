# Domo — a de-Plowed, agent-first household assistant

> **Working name:** Domo (`seed-domo`). See [Naming](#naming).
> **Status:** design + POC plan. Nothing built yet.
> **One-liner:** Take the Plow "life-dashboard" — a scheduled household briefing that
> reads your calendar/messages and pushes affirmations, a triage alert, a weekly
> digest, and meeting nudges — and rebuild it **without Plow as a dependency**,
> agent-first, running raw on the host (a Mac), on a **Claude subscription**.

---

## 1. Where this came from

The existing **Plow life-dashboard** (`team-skills/ld-*` in the plow repo, plus the
`seed-life-dashboard*` install graph) is:

- **Inputs (read-only):** calendar (`plow_calendar_search`), iMessage
  (`plow_imessage_analytics`/`_thread`), Gmail (triage).
- **Four scheduled bundles:** `ld-morning-updates` (7am affirmation),
  `ld-morning-triage` (7:05 "the one message you missed"), `ld-weekly-digest`,
  `ld-calendar-nudge` (every 30 min meeting reminder).
- **Two output surfaces:** a **kiosk** (a Pi on the wall, fed by a per-household
  **Vercel relay** + Upstash KV) and the **owner's iMessage** (via the cron's
  `delivery.channel`).
- **Strictly one-way / proactive.** It reads messages only as *data* (mood,
  triage); it never replies in a thread, never takes commands, never writes the
  calendar, never manages events. No conversational/interactive path exists.
- **Single-tenant by design.** The relay is per-household (`life-dashboard-<id>`),
  storage is one KV key (`messages:latest`, one field per type), and it's
  explicitly *"not a hosted multi-tenant relay."* Built for ~2 users.
- **The card logic is mostly prose.** Three of the four bundles are ~200-line
  `SKILL.md` instructions + a thin POST wrapper; only `ld-calendar-nudge` is real
  deterministic JS (it's LLM-free on a 30-min schedule). The README names the
  swap seam: *"To fork off-Plow: rewrite the **Gather** section."*

**"Gather"** = the input-collection phase of a skill (read calendar/messages/email),
as opposed to compose → privacy-boundary → post. It's the only Plow-specific part;
everything after it is provider-agnostic. De-Plowing = re-pointing Gather.

---

## 2. The vision for Domo

- **Agent-first.** The product is the skill-pack + the agent that runs it. The
  display is an optional downstream surface, not load-bearing.
- **Native Claude, raw on the host, lightweight.** No Docker, no servers, no Plow
  runtime. A `claude` process on a Mac + a little glue.
- **Subscription-billed.** Runs off a Claude Pro/Max subscription, not metered API.
- **One persistent session, two behaviors.** A single always-on `claude --channels`
  session (see [Channels](#41-channels-the-key-unlock)) handles both — there is no
  separate `claude -p` path:
  1. **Scheduled briefings** (the original four behaviors) — fired as scheduled
     *synthetic inbound events* injected into the channel (see [§4.2](#42-the-runtime-concretely)).
  2. **Interactive** ("talk to Domo about your day / your calendar") — ordinary
     inbound channel events.

---

## 3. The stack — replacement mapping

| Plow did this | Domo replacement | Plow-dependent? |
|---|---|---|
| Agent runtime (LLM in VM, API-keyed) | **Native Claude Code** (one persistent `claude --channels`), subscription auth | No |
| Read calendar (`plow_calendar_search`) | **claude.ai Google Calendar connector** (account-scoped) | No |
| Gmail (triage) | **same claude.ai Google Workspace connector** | No |
| Read the user's *existing* iMessage threads (mood/triage) | **`imsg`** (openclaw/imsg, host-native Swift CLI) — optional for v1 | No |
| Announce/send to owner | the channel's reply, or `imsg send` | No |
| **Interactive chat with the agent** | **Claude Code `channels`** (built-in iMessage, or a custom Plow-Chat channel) | depends on channel |
| Scheduling | one persistent `claude --channels` session; briefings = scheduled events injected into it (`/loop` in-session, or external `launchd` trigger) | No |
| Kiosk display | existing **relay + Pi viewer** seeds | No (Vercel/Upstash, not Plow) |

**Net:** the only *compelling* remaining Plow tie is **plow-chat** (the conversational
bridge on the Plow Chat API) — and even that is optional (the built-in iMessage
channel or `imsg` can replace it). Calendar/Gmail come from Google natively.

---

## 4. Architecture

### 4.1 Channels (the key unlock)

Claude Code **`channels`** (research preview, v2.1.80+) is *almost exactly* the
real-time-agent architecture we'd otherwise hand-build:

- A channel is **an MCP server that pushes inbound events into a running Claude
  session**, and is **two-way** — Claude replies through the channel's `reply` tool.
- Events arrive only while the session is open → run a **persistent
  `claude --channels …` process** (tmux/launchd) for always-on.
- **Built-in channels:** `imessage` (reads `chat.db`, replies via AppleScript,
  macOS-only, no Plow, no bot token), `telegram`, `discord`, and `fakechat`
  (localhost demo).
- **Built-in sender allowlist = the access boundary** we kept flagging as the
  missing "VIP" layer. (`/imessage:access allow +1…`; self-chat bypasses.)
- **Subscription works.** Requires claude.ai or Console auth (not Bedrock/Vertex/
  Foundry). **Pro/Max users without an org skip all enterprise gating.**

This collapses the "wrapper container + WSS server + inject inbound + hooks for
outbound" idea into native primitives:

| Hand-built idea | Channels primitive |
|---|---|
| persistent wrapper that maintains context | the persistent `claude --channels` session (auto-compaction handles growth) |
| parallel WSS server injecting inbound | the channel MCP server's event push |
| hooks routing outbound to Plow Chat | the channel's `reply` tool |
| access boundary | the built-in sender allowlist |

**For Plow Chat specifically:** build a **custom channel plugin** (per the
channels-reference) — WSS in → `reply` tool → `POST /v1/chats/{uid}/messages`. That
is the native realization of the "WSS injects context, outbound to Plow Chat" idea.
Being network-based, it's containerizable.

### 4.2 The runtime, concretely

One always-on `claude --channels` session does everything; there is no separate
`claude -p` path. Briefings are just scheduled inbound events.

```
the Mac (host-raw, subscription)
└─ ONE persistent session:
   claude --channels plugin:<fakechat|imessage|plow-chat>@…

   INTERACTIVE
     inbound channel event (owner asks about day / calendar)
       -> reads calendar via MCP -> reply via channel

   SCHEDULED BRIEFINGS  (the original four behaviors)
     trigger: /loop in-session  OR  external launchd posts into the channel
       -> Gather (Google Calendar/Gmail MCP, +imsg optional)
       -> compose -> privacy boundary -> reply (owner) / post (kiosk, optional)

   PreToolUse deny-hook = default-block allowlist (security spine)

   Isolation: CLAUDE_CONFIG_DIR=~/domo/.claude · own OAuth token · own workspace
```

> **Briefing trigger — two options.** (1) `/loop` inside the persistent session
> (zero-infra, self-pacing); (2) an external `launchd` job that posts the brief
> request into the channel (robust fallback). Self-chat bypasses the sender
> allowlist, so either lands cleanly. ⚠️ Whether `/loop` composes with channel
> event-handling in one session is **unverified** (both preview-ish) — the
> external-trigger path sidesteps it. Confirm at build time.
>
> **Bonus:** collapsing the old Tier 1 / Tier 2 into one session removes the
> "two disconnected brains" seam — briefings and chat now share one context.

---

## 5. De-Plow dependency dials

Two independent decisions, each Plow-or-not:

1. **Calendar/email:** the **claude.ai Google Calendar connector** (Plow-free) ←
   chosen. *(The first-party `calendarmcp.googleapis.com` MCP can't auth from Claude
   Code — DCR failure; `@cocal/google-calendar-mcp` is the local-server backup. Plow's
   open calendar API also works but is an unnecessary tie now.)*
2. **Conversation:** built-in iMessage channel / `imsg` (Plow-free) **vs** plow-chat
   (Plow Chat API — managed WSS + verified-member access control, but depends on
   `api.plow.co` and the single Plow user credential).

Everything else (agent, scheduler, display) is Plow-free. Hermes/Docker is **not**
used in this design — going host-raw with native Claude dissolves the container
boundary problem (see §7).

---

## 6. Auth & billing

- **Subscription auth:** two paths, no API key.
  - **POC default — interactive `/login`** in the isolated session. Since the
    runtime boots interactively anyway (to accept the channels-preview consent and
    do the one-time `/mcp` + plugin install), just `/login` once; credentials persist
    in the isolated config dir and the persistent session reuses them. No token.
  - **Unattended/cron later — `CLAUDE_CODE_OAUTH_TOKEN=$(claude setup-token)`**, the
    headless path documented for scripts/cron.
- **Per-chat memory** comes from the single persistent session staying open
  (auto-compaction handles context growth) — no `claude -p`/`--resume` plumbing.
- **Billing pools:**
  - **Before June 15, 2026:** headless runs draw the **interactive subscription
    pool** (same rolling limits as hands-on Claude Code).
  - **June 15, 2026 onward:** `claude -p` / Agent SDK / GitHub Actions draw a
    **separate monthly "Agent SDK credit" pool** — **Pro $20 / Max 5× $100 /
    Max 20× $200**, per-user, no rollover. On exhaustion: overage at API rates *if*
    usage credits are enabled, else runs are rejected until reset. Interactive
    Claude Code / Cowork stay in their own reserved pool.
  - A few briefings/day + a low-volume household chat fit comfortably in the Pro
    credit. The risk to budget is high-volume event-driven usage — the session
    firing per inbound message at high rates.
- **OPEN:** how a *backgrounded persistent* `claude --channels` session is
  classified (interactive pool vs Agent SDK credit). Subscription either way (not
  metered API on a claude.ai login), but the pool is unconfirmed.
- **Cowork:** app-only, **no programmatic/SDK access** — not usable here. (Note:
  Cowork itself already does scheduled briefings with Gmail/Calendar connectors, so
  it's a "buy" alternative for the *generic* briefing; Domo is the "build" for the
  iMessage/kiosk/household-specific parts Cowork can't reach.)
- **Agent SDK on subscription:** docs gave **conflicting** signals (requires API key
  vs works with `CLAUDE_CODE_OAUTH_TOKEN`). **Unresolved.** The persistent
  `claude --channels` session sidesteps the question entirely — we don't use the SDK
  streaming-input path; don't bet the build on it until this is settled.

---

## 7. Isolation (the "own environment" part)

- **`CLAUDE_CONFIG_DIR=<domo-home>/.claude`** relocates *everything*: settings,
  installed plugins, MCP servers, channel config, sessions, auth. Domo gets its own
  plugins, own channel allowlist — fully separate from your personal Claude Code.
  *(POC: the home defaults to the git checkout itself — `seed-domo/.claude`,
  gitignored — so the instance lives inside the project; export `DOMO_HOME=~/domo`
  to relocate.)*
- **Own login** — a fresh config dir won't inherit your main login, so the instance
  authenticates itself: interactive `/login` for the POC (stored in the isolated
  dir), or a dedicated `CLAUDE_CODE_OAUTH_TOKEN` for the unattended tier. Same
  account either way; never an API key.
- **Dedicated workspace** — `~/domo/workspace` so file tools are scoped.
- **Calendar connector is NOT isolated** — it's a **claude.ai account connector**,
  so it (and every other connector on that account) auto-loads into Domo's session on
  `/login`; there's no per-config-dir opt-out (#58453). Config/plugins/sessions/channel
  stay isolated; connectors don't. The **default-deny hook** is what keeps Domo from
  using any connector beyond the calendar read leaves — it's load-bearing for this.
- **Run model:** channels need the session *open*, so run **one persistent `claude
  --channels`** in tmux/launchd for everything — interactive chat *and* the
  scheduled briefings (injected as events). There is no separate `-p` process.
- **Container boundary:** if you ever containerize the agent, the **built-in
  iMessage channel + `imsg` break** (they need host FDA + AppleScript). Network
  channels (fakechat/telegram/custom Plow-Chat) + the Google MCP are
  container-safe. Host-raw avoids the issue entirely — that's why we chose it.

---

## 8. Security model — default-deny allowlist

POC stance: **default block, allow explicitly. Don't "handle" permissions.**

The trap: a plain `--allowedTools` allowlist makes a *non*-allowlisted tool **prompt**,
and in a backgrounded session a prompt **hangs** the session. And
`--dangerously-skip-permissions` is allow-by-default (wrong direction).

The right mechanism: a **`PreToolUse` hook** that **allows** tools on the allowlist
and **denies** everything else, with **no prompt**. This is also exactly where the
real authorization policy (the "VIP" gate) lives later.

**Verified hook contract** (cite: `code.claude.com/docs/en/hooks.md`):

- Register in (isolated) `settings.json`:
  ```json
  {
    "hooks": {
      "PreToolUse": [
        { "matcher": "*", "hooks": [ { "type": "command", "command": "<abs path>/allowlist-guard.sh", "timeout": 10 } ] }
      ]
    }
  }
  ```
- Hook receives JSON on **stdin** with `tool_name`, `tool_input`, `permission_mode`, etc.
- **Allow (no prompt):** stdout JSON, exit 0:
  ```json
  {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"on allowlist"}}
  ```
- **Deny (no prompt):** same JSON with `"permissionDecision":"deny"`, exit 0 — **or**
  the hard-block form `exit 2` (stderr message shown to Claude).
- ⚠️ **Known bug (#52822, ~v2.1.119):** a hook `"allow"` may still surface the native
  permission prompt in some versions. **Headless workaround:** use `"allow"` for
  allowlisted tools but verify no prompt appears in session logs; use **`exit 2`**
  for denials (guaranteed no prompt). Confirm against the installed version.

**POC allowlist:** the Google Calendar **read leaves** (`list_calendars`,
`list_events`, `get_event`, `suggest_time`) matched prefix-agnostically (the
connector's server segment is an account UUID), plus the channel's `reply` tool
(exact). Everything else — write leaves, every non-MCP tool (Bash, Write, Edit,
WebFetch, …), and any *other* account connector — → deny.

---

## 9. Verified technical specifics

> Confidence varies — channels and the Google Calendar MCP endpoint are recent /
> preview; re-confirm at build time against the installed Claude Code version.

### Google Calendar — via the claude.ai account CONNECTOR (chosen path)
**Decision:** use the **claude.ai Google Calendar connector**, not a locally-added MCP
server. Connect it once at `claude.ai/customize/connectors`; it is **account-scoped**
and auto-loads into any Claude Code session (incl. an isolated `CLAUDE_CONFIG_DIR`)
that `/login`s with the same account. No `claude mcp add`, no GCP OAuth client, no DCR.
- **Why not the first-party `calendarmcp.googleapis.com` HTTP MCP:** it **fails from
  Claude Code** — `claude mcp add … https://calendarmcp.googleapis.com/mcp/v1` → `/mcp`
  errors with *"Incompatible auth server: does not support dynamic client
  registration."* Claude Code's MCP client requires DCR and ignores pre-set
  `--client-id`/`--client-secret` (issues #26675, #52638, #53253). Dead end for now.
- **Tools (leaves):** `list_calendars`, `list_events`, `get_event`, `suggest_time`
  (read); `create_event`, `update_event`, `delete_event`, `respond_to_event` (write).
- **Tool naming:** connector tools surface to hooks as **`mcp__<account-UUID>__<leaf>`**
  — the UUID is account-specific, unpredictable, and changes on reconnect
  (issues #22599, #22276). So the allowlist hook **matches the read leaf and ignores
  the UUID**; the exact leaves are confirmed empirically via the deny log.
- **Scope:** the connector grants read **and** write; there is **no read-only mode**.
  Read-only is enforced *solely* by the default-deny hook (allow read leaves, deny the
  rest). This makes the hook load-bearing (see §7, §8).
- **Plan requirement:** connectors need Pro/Max/Team/Enterprise; work on subscription
  `/login` in persistent `--channels` sessions.
- **Community fallback (not chosen):** `@cocal/google-calendar-mcp` (`nspady`) — a
  local stdio server using your *own* GCP OAuth client (no DCR), kebab-case tool names
  (`list-events`, …), 7-day refresh-token expiry while the OAuth app is in "testing."
  Keep as a backup if the connector path regresses.
- Cite: `support.claude.com/.../use-google-workspace-connectors`,
  `code.claude.com/docs/en/mcp.md` ("Use MCP servers from Claude.ai").

### Channels facts
- Enable per session: `claude --channels plugin:<name>@<marketplace>` (space-separated
  for multiple).
- Marketplace: `/plugin marketplace add anthropics/claude-plugins-official` then
  `/plugin install <name>@claude-plugins-official`.
- fakechat: localhost UI at `http://localhost:8787` (port configurable via
  `FAKECHAT_PORT`, default 8787 — confirmed in the plugin source
  `Number(process.env.FAKECHAT_PORT ?? 8787)`); inbound arrives as a
  `<channel source="fakechat">` event; reply shows in the browser.
- Research preview — `--channels` flag/protocol may change.

---

## 10. POC plan (decided: fakechat first)

**Goal:** prove the whole loop with the comms layer that has zero build cost, so any
failure is unambiguously in isolation/calendar/security — not a half-built channel.

**The loop:**
> Spin up an isolated Domo Claude → it has Google Calendar (read) via MCP + the
> fakechat channel + the default-deny hook → type *"what's on my calendar today?"*
> in the fakechat UI → it calls the calendar connector → replies in the browser with
> your events.

**Build (the `seed-domo` POC artifacts):**
1. `run.sh` — sets `CLAUDE_CONFIG_DIR`/token/workspace; a one-time `setup`
   (add Google MCP + `/mcp` OAuth, install fakechat) and a `start` (persistent
   `claude --channels plugin:fakechat@claude-plugins-official`).
2. `hooks/allowlist-guard.sh` — default-deny PreToolUse hook (allow = calendar read
   tools + fakechat `reply`; deny everything else via the verified contract).
3. `config/settings.json` — registers the hook.
4. `README.md` — one-time interactive steps (Google OAuth, plugin install) vs the
   persistent headless run.

**Acceptance criteria:**
1. Inbound text arrives as a `<channel source="fakechat">` event.
2. Claude calls **only** allowlisted tools (calendar read + reply) — confirm the
   hook denies anything else, no prompt/hang.
3. Reply lands in the fakechat UI with the correct events.

**Then:** swap the channel from fakechat → built-in `imessage` (real phone loop,
still Plow-free) → optionally a **custom Plow Chat channel** (dedicated agent line +
verified-member auth). Everything else stays put.

**One-time interactive steps (can't be headless):** Google connector `/mcp` OAuth;
channel install/pairing. After that the listener + hook run unattended.

---

## 11. Open questions / risks

- **Persistent-session billing pool** (interactive vs Agent SDK credit) — confirm.
- **Agent SDK on subscription** — unresolved; the persistent `--channels` session avoids it.
- **PreToolUse "allow" prompt bug (#52822)** — verify behavior on installed version;
  fall back to `exit 2` for denials.
- **Calendar = claude.ai connector** — confirm the read-tool **leaf** names via the
  deny log (tool surface is `mcp__<account-UUID>__<leaf>`, UUID unpredictable). Note:
  connector is **account-scoped** (inherits *all* account connectors; no per-config-dir
  opt-out, #58453) and grants **read+write** (no read-only scope) — the default-deny
  hook is the only thing enforcing read-only. First-party `calendarmcp.googleapis.com`
  is unusable from Claude Code (DCR failure); community `@cocal/google-calendar-mcp` is
  the backup.
- **Channels = research preview** — flag/protocol may change.
- **Briefing trigger** — whether `/loop` composes with channel event-handling in one
  session is unverified; external `launchd`-into-channel trigger is the fallback.
- **Authorization gap when interactive:** the moment Domo can *send to others* or
  *act* (write calendar, group coordination), the sender allowlist / a real
  authorization policy is load-bearing. An autonomous agent + send capability +
  unvetted inbound = prompt-injection footgun. Keep the safe core **read + reply to
  owner/allowlisted only** until a real policy exists.
- **iMessage = Mac-only** (chat.db + FDA + Automation). Unavoidable for the iMessage
  features.

---

## 12. Explicitly out of scope (for now)

- Group chat that **manages events** (agent writes/RSVPs calendar from a thread) —
  net-new; needs calendar *write* + a confirm-before-write gate + an authorization
  policy. The current/original design never writes the calendar or replies in
  threads.
- Real-time "react to an urgent message as it arrives" — buildable (imsg watch /
  channel inbound) but a later tier.
- Multi-tenant / multi-household — single-tenant per install, like the original.

---

## Naming

**Domo** — from *domus* (home) + *majordomo* (household steward); short, friendly,
means "home" and "steward." Non-anthropomorized alternatives considered: **Dispatch**
(the daily brief that gets sent), **Almanac** (daily record + forecast), **Cadence**.
Convention: `seed-domo`, `seed-domo-agent`, `seed-domo-relay`, etc.

---

## Appendix — the original seed graph (for reference)

`seed-life-dashboard` (umbrella) walks: `seed-life-dashboard-relay` (Vercel relay +
Upstash KV, per-household), `seed-life-dashboard-agent` (the five `ld-*` bundles into
Plow), `seed-life-dashboard-viewer` (the Pi kiosk: React SPA + Node proxy + the
Vercel `api/message` functions). Auth to the relay is a single static bearer
(`DASHBOARD_TOKEN`), validated server-side for both POST (write) and GET (read);
storage is one Upstash hash `messages:latest`, one field per type. The kiosk also
pulls calendar **directly via ICS** (independent of Plow). Hermes path (Docker,
`openai-codex`/ChatGPT auth, `seed-hermes` + optional `seed-hermes-plow-chat` gateway)
was considered but **not** chosen — Domo goes host-raw with native Claude instead.
