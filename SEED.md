# Purpose

> See [README#Purpose](README.md#purpose).

## Normative Language

The key words MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD NOT,
RECOMMENDED, MAY, and OPTIONAL in this document are to be interpreted as
described in RFC 2119. Sub-folder `SEED.md` files in this tree inherit this
declaration and MUST NOT re-declare it.

## Dependencies

`seed-domo` describes how to stand up a personalized Domo; it does not silently
install anything system-wide. Each dependency below is **surfaced and verified**,
ordered API first, then software. Two of them — interactive `/login` and the
claude.ai Google Calendar connector — are **user-only (tier-3) steps the agent
MUST NOT and cannot perform for the user** (they require a human at a browser /
account session); the agent surfaces them, waits, and then verifies them.

**API**

- **Claude subscription (interactive `/login`)** — Domo runs on an Anthropic
  Claude subscription, signed in interactively via `/login` inside the isolated
  Claude config dir. The agent MUST NOT supply an API key: `ANTHROPIC_API_KEY`
  MUST be unset so subscription auth is used and billing never silently falls
  back to a metered key. This is a **user-only (tier-3) step**: the agent cannot
  complete `/login` for the user; it MUST surface the step, then verify the
  instance is authenticated and that `ANTHROPIC_API_KEY` is unset.
- **claude.ai Google Calendar connector** — the Google Calendar connector
  enabled at the **account** level in claude.ai (browser; account-scoped). Once
  enabled it surfaces inside Claude Code as the `mcp__claude_ai_Google_Calendar__*`
  tools. This is a **user-only (tier-3) step**: the agent cannot perform the
  browser OAuth on the user's behalf, so it MUST surface the step and then verify
  the tools are available — it is **verified, not executed**.
- **Plow Chat API, via the external SEED
  [seed-plow-chat](https://github.com/plow-pbc/seed-plow-chat)** — the texting
  surface (line, chat, auth/activation, WSS inbound, REST post, restart-safe
  backfill) is owned by the external SEED at
  `https://github.com/plow-pbc/seed-plow-chat`. It MUST be installed
  **leaves-first** (the external SEED before this one), because it owns the
  channel/auth/WSS/post contract that the Domo channel object speaks. The SEED
  does not prescribe where to clone it: the agent chooses the location (a sibling
  checkout alongside `seed-domo` is conventional) and SHOULD refer to it as
  `$SEED_PLOW_CHAT_ROOT`. The clone URL MUST carry no userinfo, query, or fragment.

**Software**

- **macOS** — Domo targets macOS; non-macOS hosts are unsupported (see
  Non-Goals). The daemon relies on macOS `/usr/bin/script` for a controlling PTY.
- **Claude Code CLI ≥ 2.1.80** — the `claude` CLI MUST be on `PATH` at version
  2.1.80 or newer (the `--channels` research preview).
- **`bun`** — the JavaScript runtime that runs the channel MCP server and the
  small JSON/activation helpers. It MUST be on `PATH`.
- **`jq`** — used to render the readable transcript feed. It SHOULD be present;
  without it the reference falls back to the raw PTY log.
- **`expect`** — drives the once-per-launch dev-channels confirmation so the
  background daemon can start headlessly. It MUST be present for the backgrounded
  custom-channel launch.

The reference channel under `ref/channels/plow-chat` needs `bun install` in that
directory only if the agent chooses to run or extend the reference; nothing in
this SEED REQUIRES running `ref/`.

## Objects

A running Domo is composed of the following named entities. This section is
descriptive: it names the parts so Actions and Verify can refer to them.

- **The Domo session** — one persistent `claude --channels` process. It uses
  subscription auth (never an API key) and runs with `--permission-mode auto`
  (classifier-gated, not `bypassPermissions`). Reference: `ref/domo`.
- **The channel** — an MCP stdio server implementing the `claude/channel`
  capability over Plow Chat: inbound over WSS, outbound via REST POST, and
  restart-safe backfill that de-dupes by message uid so a daemon restart does
  not replay history. It reads its secrets (`base_url`, the Bearer token,
  `chat_uid`) from a chmod-600 state file whose absolute path is passed via the
  `PLOW_CHAT_STATE` environment variable; it MUST NOT hardcode the path and MUST
  NOT log the token. Reference: `ref/channels/plow-chat`.
- **The daemon** — the backgrounded, detached session with **session resume** via
  a single pinned session UUID, so the foreground (`shell`) and background
  (`start`) launches are one continuous conversation. The once-per-launch
  dev-channels confirmation is answered headlessly through a PTY/`expect` driver.
  Reference: `ref/domo` plus `ref/bin/spawn-confirm.expect`.
- **The chat** — a Plow chat, in one of two shapes. **Solo** is one member (a 1:1
  texting line). **Group** is N members. Each member is verified by texting a
  one-time `VERIFY-XXXXXX` code; inbound frames carry
  `message.sender.display_name`, so the agent always knows who is talking. Solo
  vs group is **not** a runtime toggle or a shipped flag — it is a property the
  install interview decides, and it changes the software the agent writes.
- **The workspace** — the agent's working directory plus a `CLAUDE.md` holding
  household context: who is in the chat, the persona, and the trust posture.
  Runtime state (config, sessions, run dir, channel state) lives gitignored at
  the repo root.
- **The calendar tools** — the `mcp__claude_ai_Google_Calendar__*` tools that
  appear from the account-level claude.ai connector. They let Domo read and
  manage the household calendar.

## Actions

These are the verbs of a Domo's lifecycle. Contracts use RFC 2119 language.

### Domo is installed

The one-shot, interview-driven onboarding — run end-to-end by the installing
agent, in real time, so it ends with a **live, ready-to-go Domo** rather than a
pile of settings and commands for the user to run afterward. **The SEED does not
ship a configurable product and the agent MUST NOT dictate a shape.** The agent
**interviews the user up front**, then **writes custom Domo software** tailored to
the answers and **runs the mechanics itself inline**, consulting `ref/` for how
the pieces work. `ref/` is **reference only**: a working example the agent MAY
reuse, adapt, or replace, as long as the security invariants below hold.

The division of labor is fixed: the agent runs everything it can and pauses only
for the genuinely **user-only (tier-3)** steps, resuming automatically once they
are done. The user-only steps are exactly: interactive `/login`, enabling the
claude.ai Google Calendar connector in the browser, and texting the Plow
verification code(s) from the relevant phone(s). Setup, activation orchestration,
and starting the daemon are run **by the agent**, not handed to the user.

**This Action *is* installing Domo, and it is the root SEED's post-install hook.**
A generic SEED conformance pass (clone, `## Dependencies`, the install-time
`## Verify` prompts) is the scaffolding, not the finish line — on its own it
leaves Domo unbuilt and not running. So as soon as a fresh conformance install
reaches `terminal` with the install-time `## Verify` prompts green, the installer
SHOULD offer to run this Action immediately and **continue straight into it**
(surfacing the user-only steps inline) rather than stopping with a printed command
for the user to run later. "Installed" is not the goal; **"running" is**: done is
defined by the runtime `## Verify` prompts (signed in, daemon answering texts). The
agent SHOULD drive to that state in one continuous flow, pausing only for the
user-only steps, so the experience ends with a live Domo or one confirmation away
from it — never a conformance install with no actual Domo.

The agent MUST complete the following checklist (an agent SHOULD map each item to
its task tracker):

1. **Interview the user up front.** In a single pass, ask everything needed to
   author and stand up their Domo: how they want to use it (solo vs group —
   tier-2; member names, persona, trust posture — tier-3), and confirm they can
   complete the user-only steps. Front-loading the questions means the rest of the
   install runs without further interruption. The agent MUST record the answers as
   the household context and MUST NOT assume a shape the user did not choose.
2. **Satisfy the Dependencies inline.** Install/confirm the software deps and
   install the [seed-plow-chat](https://github.com/plow-pbc/seed-plow-chat)
   external SEED leaves-first. For the two user-only steps, prompt and then
   **verify in real time**:
   - **Google Calendar connector** — direct the user to enable Google Calendar at
     claude.ai for the account they will `/login` with, then **confirm access by
     checking that the `mcp__claude_ai_Google_Calendar__*` tools actually appear**
     (e.g. list calendars). The agent MUST confirm calendar access, not assume it.
   - **Interactive `/login`** — have the user sign in to the subscription in a real
     TTY; the agent MUST NOT supply an API key and MUST confirm `ANTHROPIC_API_KEY`
     is unset.
3. **Author the user's custom Domo software.** Write the Domo to match the
   interview, consulting `ref/` for the channel contract, the backgrounded
   `claude --channels` daemon with session resume, the dev-channels confirmation,
   and `--permission-mode auto`. The authored software MUST keep
   `ANTHROPIC_API_KEY` unset, MUST store the Plow Bearer token chmod-600 and never
   log/print/commit it, and MUST use clone URLs with no userinfo/query/fragment.
4. **Run setup and activation inline.** The agent itself runs the bootstrap and
   the Plow activation handshake **as part of the install** — obtaining the Plow
   Bearer token is an install step, not a command left for the user to run later.
   The agent surfaces the verification code(s) for the user(s) to text and waits
   for the chat to go active. The activation secret MUST be passed via stdin, never
   argv; the token MUST be written chmod-600.
5. **Start the daemon inline.** The agent launches the persistent background
   session (pinned session UUID, headless dev-channels confirmation) so Domo is
   live by the end of the install.
6. **Verify.** Run the Verify prompts below — both the install-time and the runtime
   prompts (the runtime prompts now pass, because the agent ran activation and
   start inline) — and confirm each returns its expected answer before declaring
   the install complete.

### Domo is activated

The Plow handshake that yields a Bearer token and a chat. It is documented in
**both** shapes so an authoring agent has a concrete example of either; neither
is a shipped toggle.

- **Solo** — use the activation shortcut: `POST /v1/auth/activate
  {provision_chat: true}` returns one display code; the user texts it; redeem
  yields the user-wide Bearer token plus a 1:1 chat. The token MUST be written
  chmod-600 to the state file and MUST NOT be logged, printed, or committed.
- **Group** — activate to obtain the token and a line, then `POST /v1/chats` with
  `participants = [{agent, line_id}, {member, display_name}, …]`. Each member
  texts their one-time `VERIFY-XXXXXX`; the channel observes `participant_verified`
  frames until every participant is `active`.

### Domo runs

The background daemon keeps the session alive: it resumes the pinned session UUID
so `shell` and `start` are one continuous conversation, and it answers the
once-per-launch dev-channels confirmation through the PTY/`expect` driver. The
daemon MUST be reapable by its scoped session signature (so two Domo instances
never reap each other) and MUST NOT print secrets in its logs.

### Domo replies / reads the calendar / reports activity

The runtime verbs. Domo **replies** to texts through the channel `reply` tool
(anything the user should see MUST go through `reply`; transcript output does not
reach them). Domo **reads the calendar** through the
`mcp__claude_ai_Google_Calendar__*` connector tools. Domo **reports activity**
through the transcript-feed logs (a readable 📥/📤/⚙ feed), which MUST NOT contain
the Bearer token or any other secret.

## Verify

Verification is a sequence of natural-language prompts an agent reads and answers;
the Domo is conformant when every prompt returns its expected answer. The prompts
are split by *when* they can pass. **Install-time** prompts hold once
`## Dependencies` are satisfied; **runtime** prompts hold only after the
interview-driven *Domo is installed* Action has stood up a live session. A
mechanical Dependencies-then-Verify sweep on a fresh clone can satisfy the
install-time prompts but MUST NOT be expected to satisfy the runtime prompts —
those pass only after a full install. The deterministic implementation of the
structural check lives at `ref/verify.sh`.

**Install-time** — an agent can confirm these on a fresh clone once
`## Dependencies` are satisfied, independent of the human `/login` and before a
live Domo is running:

1. **Tooling present.** Are `bun`, `jq`, and `expect` on `PATH`, and is
   `claude --version` ≥ 2.1.80?
2. **No API key.** Is `ANTHROPIC_API_KEY` **unset**, so subscription auth is used
   and billing never falls back to a metered key? This invariant is
   deterministically checkable and MUST hold independent of the human `/login`.
3. **Calendar connector.** Are the `mcp__claude_ai_Google_Calendar__*` tools
   available from the account-level connector?
4. **Structural conformance.** Do the three SEED structural checks pass?
   a. The repo `README.md` contains a `## Purpose` H2 (outside code blocks).
   b. The root `SEED.md` has exactly one H1 (`# Purpose`), matches the canonical
      H2 grammar, and includes the `## Normative Language` section.
   c. Every `SEED.md` in the tree has a `# Purpose` body that is a single line
      linking to its sibling-or-ancestor `README#Purpose`, and sub-folder
      `SEED.md` files omit `## Normative Language`.

**Runtime** — these hold only after the *Domo is installed* Action has run
(interview, authoring, `/login`, activation, and `start`):

5. **Subscription sign-in.** Is the instance authenticated on a Claude
   subscription via interactive `/login` (the tier-3, user-only step)?
6. **Channel + daemon.** Is the channel MCP server registered, and does the
   daemon resume the pinned session (e.g. `ref/domo doctor` / `ref/domo status`
   reports green)?

## Feedback

(none)

## Open

- **Morning briefing trigger** — a cron-injected morning message so Domo proactively
  briefs the household. Deferred.
- **Reboot survival** — a launchd job so the daemon survives a host reboot.
  Deferred.
- **Per-sender gating** — finer-grained authorization per sender. Deferred; the
  current trust posture is all-verified-members-equal.

## Non-Goals

- **No headless `claude -p`** — Domo is channels-only; it is not driven by
  one-shot `claude -p` prompting.
- **No API key** — `ANTHROPIC_API_KEY` stays unset; Domo is subscription-billed
  and MUST NOT fall back to a metered key.
- **No shipped configurable product** — this SEED authors bespoke software per
  user (interview, then write); it does not ship a single product with a
  solo/group flag.
- **Non-macOS** — non-macOS hosts are unsupported.
