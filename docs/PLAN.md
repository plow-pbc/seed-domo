# Domo — a de-Plowed, agent-first household assistant

> **Working name:** Domo (`seed-domo`). See [Naming](#naming).
> **Status:** design built. The `domo` CLI (background daemon + session resume) and a
> custom **plow-chat** channel (the real texting surface) are implemented; `fakechat` is
> demoted to a local test channel. See §10. Live runtime items are flagged verify-at-launch.
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
└─ ONE persistent session, run by the `domo` CLI as a background daemon:
   claude --channels plugin:<plow-chat|fakechat|imessage> [--plugin-dir …] \
          --permission-mode auto  --session-id/--resume <pinned-uuid>

   INTERACTIVE
     inbound channel event (owner asks about day / calendar)
       -> reads calendar via MCP -> reply via channel

   SCHEDULED BRIEFINGS  (the original four behaviors)
     trigger: /loop in-session  OR  external launchd posts into the channel
       -> Gather (Google Calendar/Gmail MCP, +imsg optional)
       -> compose -> privacy boundary -> reply (owner) / post (kiosk, optional)

   Permissions: --permission-mode auto (classifier-gated auto mode; no custom allowlist — §8)

   Lifecycle: `domo start` (background, PTY-wrapped) / `stop` (tree-kill) / `status` / `logs`;
              `domo shell` is the foreground TTY for one-time consent/login/debug.
              shell + start share ONE pinned session UUID (resume) — see §10.

   Isolation: CLAUDE_CONFIG_DIR=<domo-home>/.claude · own login/token · own workspace
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
  stay isolated; connectors don't. ⚠️ With no custom allowlist (§8, auto mode), only
  the generic classifier scopes what Domo does with other account connectors — it'll
  soft-block their risky *writes* but may allow *reads*. Keep the account's connected
  surface minimal until a Domo-specific guard returns.
- **Run model:** channels need the session *open*, so run **one persistent `claude
  --channels`** for everything — interactive chat *and* the scheduled briefings
  (injected as events). There is no separate `-p` process. The **`domo` CLI** manages
  this: `domo start` launches it as a detached **background daemon** (PTY-wrapped via
  `/usr/bin/script` since macOS has no `setsid`, with a PID file + logfile; `stop`
  tree-kills the orphaned PTY child), so no user-run tmux/launchd is required — though a
  launchd `KeepAlive` wrapping `domo start` is the documented fallback if the
  backgrounded session doesn't survive (verify-at-runtime, §10).
- **Container boundary:** if you ever containerize the agent, the **built-in
  iMessage channel + `imsg` break** (they need host FDA + AppleScript). Network
  channels (fakechat/telegram/custom Plow-Chat) + the Google MCP are
  container-safe. Host-raw avoids the issue entirely — that's why we chose it.

---

## 8. Security model — POC uses Claude Code "auto mode" (classifier-gated)

**Current decision:** no custom allowlist — the persistent session launches in
**`--permission-mode auto`**, Claude Code's built-in **classifier-gated auto mode**
(the shift+tab mode in the UI; v2.1.x). We removed the default-deny `PreToolUse` hook
because it blocked the channel `reply` tool (Domo couldn't answer in the fakechat UI),
and auto mode turns out to be a better baseline than a hand-rolled allowlist.

**What auto mode does** (live ruleset via `claude auto-mode defaults`): a classifier
sorts each tool call into **allow** / **soft_deny** / **hard_deny**:
- **allow (auto-approved, no prompt):** read-only ops, the channel `reply` ("answering
  the user"), local file ops *within the project*, declared-dependency installs, memory
  writes. → Domo's normal **calendar-read + reply** loop is here, so it never prompts
  and never hangs the backgrounded session.
- **soft_deny (blocked, user-overridable):** destructive git, prod deploys,
  **irreversible local destruction**, **external-system writes**, real-world
  transactions, credential exfil scouting.
- **hard_deny (always blocked):** **data exfiltration** across the trust boundary,
  working around the classifier.

**Why `auto` and not `bypassPermissions`:** `bypassPermissions` (≡
`--dangerously-skip-permissions`) is allow-**everything**, no classifier — a blank
check. `auto` keeps the important guards (exfiltration hard-blocked, risky writes
soft-blocked) while still auto-approving the safe path so nothing hangs. Override via
`DOMO_PERMISSION_MODE` if needed.

**⚠️ Residual risk (eyes open).** Auto mode is a *generic* safety classifier, not a
Domo-specific policy. It does **not** stop calendar **write** tools
(`create_event`/`update_event`/`delete_event`/`respond_to_event`) on the owner's *own*
calendar, and an always-on agent ingesting **untrusted inbound text** is still a
prompt-injection surface for whatever auto mode classifies as "safe." Good enough for a
single-user POC reading the owner's calendar and replying to the owner; before Domo can
act on **others** or coordinate from a thread, add a Domo-specific authorization layer
on top of auto mode.

**If a custom guard returns** (the design we built and pulled, kept here as a quick
re-add): a **`PreToolUse` hook** that allows an explicit allowlist and denies the rest
with **no prompt** — allow `exit 0` + stdout `{"hookSpecificOutput":{"hookEventName":
"PreToolUse","permissionDecision":"allow",…}}`, deny via **`exit 2`** (guaranteed-no-
prompt hard block; cite `code.claude.com/docs/en/hooks.md`). Match the tool **leaf**
and ignore the server segment. **Observed live tool names** (use these for the allowlist):

- Calendar (read): `mcp__claude_ai_Google_Calendar__{list_calendars,list_events,get_event,suggest_time}`
- Calendar (write — keep OUT): `…__{create_event,update_event,delete_event,respond_to_event}`
- Channel: `mcp__plugin_fakechat_fakechat__{reply,edit_message}` (allow `reply`)

⚠️ Note the **`allow`-still-prompts bug #52822** (~v2.1.119): if you re-add the hook,
verify allowlisted tools don't raise a prompt; rely on `exit 2` for denials.

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
  With no custom allowlist (§8, auto mode), nothing Domo-specific enforces read-only;
  auto mode soft-blocks some calendar writes (e.g. `respond_to_event` as an external
  write) but does not reliably block writes to your *own* calendar. Re-adding the leaf
  allowlist is how strict read-only comes back.
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

## 10. The build — `domo` CLI + custom plow-chat channel (fakechat demoted to test)

The POC proved the loop on `fakechat` (localhost UI, zero build cost). This pass
promotes the **real surface**: a **custom Plow Chat channel** (a real SMS/texting line
with verified-member access control) plus a **`domo` CLI** that runs the session as a
**background daemon** with **session resume**. `fakechat` is now a **test channel** —
selectable for local debugging with no Plow activation.

**The loop (real surface):**
> Spin up an isolated Domo Claude → Google Calendar via the claude.ai **connector** +
> the **plow-chat** channel, in **auto mode** → **text the bound phone line** *"what's
> on my calendar today?"* → it calls the calendar connector → **replies as a text**
> through the channel's `reply` tool (`POST /v1/chats/{uid}/messages`).

**Build (the `seed-domo` artifacts):**
1. **`channels/plow-chat/`** — a custom channel plugin in bun/TS mirroring `fakechat`'s
   contract exactly, swapping only the transport: a **Plow Chat WSS client + REST
   sender**, **no localhost listener** (so no port to bind/conflict). Packaging:
   `.claude-plugin/plugin.json` + `.mcp.json` (bun launch, like fakechat) + `server.ts`.
   - **INBOUND:** mint ticket `POST /v1/ws/ticket` → connect `wss?ticket=…` → on
     `message_received` push a `notifications/claude/channel` event (ignoring
     `direction=='outbound'` echoes). On disconnect: re-mint + backfill via
     `GET /v1/chats/{uid}/messages`, de-duped by message uid against a persisted
     `last_seen.json` high-water mark (so a restart does **not** replay history).
   - **OUTBOUND:** the `reply` tool → `POST /v1/chats/{uid}/messages` (`409
     chat_not_ready` surfaces an error; not retried until the chat is active).
   - **Secrets:** read from a chmod-600 state file whose path is in `PLOW_CHAT_STATE`
     (mirrors how fakechat receives `FAKECHAT_PORT`). If state is missing the server
     still starts the stdio transport so `claude --channels` loads cleanly, but stays
     unconnected and `reply` returns `isError` until state appears — it never crashes
     the transport. State is re-read lazily on each send/reconnect (late-activation
     pickup, best-effort).
2. **`domo`** — the orchestrator CLI (evolves `run.sh`; keeps its isolation, auto-mode,
   optional-token auth, `ANTHROPIC_API_KEY`-unset guard). Commands:
   `setup` (dirs + workspace + **pinned session UUID** in `.claude/domo.json` + channel
   loadable via `--plugin-dir`), `activate` (the Plow handshake in bash+curl: POST
   activate → print the `display_code`/`send_to` to text → poll redeem → write the
   chmod-600 `{base_url,token,chat_uid}` state), `shell` (foreground TTY: one-time
   channels consent / `/login` / debug), `start` (the **same** session in the
   **background**, detached, PID + logfile), `stop` (tree-kill the daemon + sweep the
   stray channel child), `status`, `logs`, `doctor`.
3. **`README.md`** — operator guide for the above.

- **Session resume — one pinned UUID** shared by `shell` and `start` so they are ONE
  continuous conversation. `setup` mints it; first run launches `--session-id <uuid>`,
  later runs `--resume <uuid>` (detected by whether the workspace project-dir jsonl
  exists). `--permission-mode auto` is kept in every path.
- **Channel selector:** `DOMO_CHANNEL=plow-chat` (default, the real surface) | `fakechat`
  (local test, marketplace-installed, no Plow activation). The channels flag and
  per-channel env (`PLOW_CHAT_STATE` vs `FAKECHAT_PORT`) follow from the selection.

*(Still removed: the `hooks/allowlist-guard.sh` default-deny hook + `config/settings.json`
— see §8. They return when a real authorization policy does; do NOT reintroduce as the
default.)*

**Acceptance criteria:**
1. A texted message arrives as a `<channel source="plow-chat" chat_id="…"
   message_id="…">` event (meta carries the sender's `provider_key`).
2. Claude reads the calendar via the connector (`mcp__claude_ai_Google_Calendar__*`),
   auto-approved by auto mode.
3. The reply lands **as a text** (`POST /v1/chats/{uid}/messages`) with the correct
   events — no prompt/hang.
4. `./domo stop && ./domo start` resumes the SAME session and does NOT replay chat
   history to Claude on restart.

**Runtime-verify items (could not be checked statically; no token/`claude` run):**
- A backgrounded `claude --channels` survives without a TTY. `start` wraps it in a
  `/usr/bin/script` PTY (macOS has no `setsid`); `stop` therefore **tree-kills** because
  the PTY child is orphaned in its own session when the wrapper dies. Escape hatch:
  `DOMO_NO_PTY=1`.
- `--session-id`/`--resume` **compose with** `--channels`; and a `--plugin-dir`-loaded
  channel is addressable as `plugin:plow-chat`. Escape hatch: `DOMO_SESSION_FALLBACK=1`
  (resume the latest jsonl by mtime); fallback for addressing is a one-off local
  marketplace.
- The live Plow loop (activate handshake, WSS reconnect/backfill, outbound-echo
  filtering, the `last_seen` cursor — the messages endpoint exposes no documented
  `after`/`since` param, so de-dup is client-side; the message timestamp field name is
  unconfirmed).

**One-time interactive steps (can't be headless):** connect the Google Calendar
connector at claude.ai; `./domo shell` then `/login` (+ accept the channels-preview
consent); `./domo activate` (text the code). After that the daemon runs unattended.

> **Built-in `imessage`** (real phone loop, Plow-free, but Mac-only chat.db + FDA +
> AppleScript) remains a non-Plow alternative to plow-chat; the channel contract is the
> same, so swapping `DOMO_CHANNEL` is the only change.

---

## 11. Open questions / risks

- **Persistent-session billing pool** (interactive vs Agent SDK credit) — confirm.
- **Agent SDK on subscription** — unresolved; the persistent `--channels` session avoids it.
- **No Domo-specific guard (auto mode, §8)** — the POC runs `--permission-mode auto`
  (classifier-gated): it hard-blocks exfiltration and soft-blocks risky writes, but
  does **not** Domo-scope tools — calendar **writes on your own calendar** and local
  workspace ops are auto-approved on an agent fed untrusted inbound. Tracked as the top
  risk to close before Domo can send-to-others or coordinate from a thread. (Re-add: a
  leaf allowlist via `PreToolUse` hook on top of auto mode; beware the
  `allow`-still-prompts bug #52822, use `exit 2` for denials.)
- **Calendar = claude.ai connector** — account-scoped (inherits *all* account
  connectors; no per-config-dir opt-out, #58453) and grants **read+write** (no
  read-only scope). Live tool surface confirmed: `mcp__claude_ai_Google_Calendar__*`.
  First-party `calendarmcp.googleapis.com` is unusable from Claude Code (DCR failure);
  community `@cocal/google-calendar-mcp` is the backup.
- **Channels = research preview** — flag/protocol may change.
- **Backgrounded session survival** — whether a PTY-wrapped `claude --channels` stays
  alive headless after the launching shell exits (and events still flow) is
  verify-at-runtime; `DOMO_NO_PTY=1` and a launchd `KeepAlive` over `domo start` are the
  fallbacks (§10).
- **Session resume composes with channels** — whether `--session-id`/`--resume` work
  alongside `--channels` (and a `--plugin-dir` channel is addressable as
  `plugin:plow-chat`) is verify-at-runtime; `DOMO_SESSION_FALLBACK=1` (latest-jsonl
  resume) and a one-off local marketplace are the fallbacks (§10).
- **Live Plow loop** — the `activate` handshake, WSS reconnect/backfill, outbound-echo
  filtering, and the client-side `last_seen` cursor (no documented `after`/`since` param;
  message timestamp field name unconfirmed) are statically reviewed but not exercised
  (no token; calling would hang).
- **Untrusted inbound is now real.** With plow-chat the inbound is **real texts from a
  bound phone line**, not the local-only fakechat UI — so the prompt-injection surface is
  live. Plow's verified-member access control bounds *who* can text the line, but auto
  mode is still the only thing scoping *what Domo does* with that input. Keep the safe
  core read+reply-to-owner until a Domo-specific guard returns (above).
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
