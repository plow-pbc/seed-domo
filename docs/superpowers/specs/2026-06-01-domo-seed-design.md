# Design: seed-domo — a SEED for an agent-authored household Domo

**Date:** 2026-06-01
**Status:** approved-pending-review

## Purpose & philosophy

`seed-domo` is a **SEED** (per the [plow-pbc/seed](https://github.com/plow-pbc/seed)
convention): a descriptive, non-dictating knowledge base plus reference
implementation that an agent uses to stand up a **personalized "Domo"** — a
de-Plowed, agent-first household assistant that runs as one persistent
`claude --channels` session on a Mac, on a Claude subscription.

The SEED **does not ship a configurable product.** It *describes* how Domo works
and walks an agent + user through a one-shot install where the agent:

1. Walks through every requirement (tooling, sign-in, the claude.ai Google
   Calendar connector, the channel contract).
2. **Interviews the user** — how do you want to use Domo? (solo / group / whoever
   / however).
3. **Writes custom Domo software** tailored to exactly that, consulting `ref/`
   for the mechanics but free to build it however the user wants.

**`ref/` is pure implementation reference** — a working example of the moving
parts (the Plow Chat channel, the backgrounded `claude --channels` daemon with
session resume, the dev-channels confirmation, `--permission-mode auto`, the
calendar connector). The agent and the user read it to understand *how*; nothing
in the SEED requires running or copying it verbatim. If the user wants to write
their Domo and go, that's fine; the reference is there to show how the pieces fit.

### Non-dictation principle

The SEED describes capabilities and mechanics; it never forces a shape. "Solo vs
group" is not a runtime toggle or a shipped flag — it is one of the things the
install **asks**, and the answer changes what software the agent **writes** for
that user. The SEED documents *both* shapes as reference patterns so the agent
can author either (or something else entirely).

## Repo layout (after the reframe)

```
seed-domo/
  SEED.md                      # NEW — the normative description (canonical grammar)
  README.md                    # REWRITE — adds ## Purpose; existing operator guide → ## Usage
  ref/                         # pure implementation reference (a working example)
    domo                       # MOVED from root; paths rebased to run from ref/
    bin/spawn-confirm.expect   # MOVED
    channels/plow-chat/        # MOVED (server.ts, package.json, .mcp.json, ...)
    verify.sh                  # NEW — deterministic impl of the SEED Verify prompts
  docs/
    PLAN.md                    # MOVED from root (design history; not SEED grammar)
    superpowers/specs/2026-06-01-domo-seed-design.md   # this spec
  .gitignore                   # paths updated for the ref/ move
```

- **No root `domo` shim, no `run.sh`.** The repo root stays clean
  (`SEED.md`, `README.md`, `ref/`, `docs/`). `run.sh` is deleted.
- **`ref/domo` stays runnable** (a live reference, not dead code): it rebases its
  own location so `REPO_ROOT = dirname(dirname(realpath script))`. Runtime state
  (`.claude/`, `workspace/`, run dir, plow-chat state) continues to live at the
  **repo root** (gitignored); the channel dir and the expect driver resolve under
  `ref/`.
- The user's currently-running solo daemon is a live process and is unaffected by
  the file moves.

## SEED.md (canonical H2 grammar, RFC 2119)

- `# Purpose` → `> See [README#Purpose](README.md#purpose).` (nothing else).
- `## Normative Language` (root only).
- `## Dependencies` (ordered API → software; surfaced, not auto-run system-wide):
  - **API**
    - Anthropic **Claude subscription**, signed in interactively via `/login`
      (no API key; `ANTHROPIC_API_KEY` MUST be unset). User-only step (tier-3).
    - The claude.ai **Google Calendar connector** enabled at the account level
      (browser; account-scoped, surfaces in Claude Code as
      `mcp__claude_ai_Google_Calendar__*`). User-only step (tier-3); the agent
      cannot OAuth for the user. Verified, not executed.
    - The Plow Chat API, via the **external SEED**
      `https://github.com/plow-pbc/seed-plow-chat` (installed leaves-first; it
      owns the channel/auth/WSS/post contract).
  - **Software**: macOS; Claude Code CLI ≥ 2.1.80 (channels research preview);
    `bun`; `jq`; `expect`. The reference channel needs `bun install` in
    `ref/channels/plow-chat` only if the agent runs/extends the reference.
- `## Objects` (descriptive — the named entities of a running Domo):
  - **Domo session** — one persistent `claude --channels` process; subscription
    auth; `--permission-mode auto` (classifier-gated, not bypass).
  - **The channel** — an MCP stdio server implementing the `claude/channel`
    capability over Plow Chat (inbound WSS, outbound POST, restart-safe backfill).
    Reference: `ref/channels/plow-chat`.
  - **The daemon** — the backgrounded, detached session with **session resume**
    via a pinned UUID; the once-per-launch dev-channels confirmation answered
    headlessly. Reference: `ref/domo` + `ref/bin/spawn-confirm.expect`.
  - **The chat** — a Plow chat. Solo = one member; group = N members. Each member
    is verified by texting a one-time `VERIFY-XXXXXX`; inbound frames carry
    `message.sender.display_name`, so the agent always knows who is talking.
  - **The workspace** — the agent's cwd plus `CLAUDE.md` household context (who is
    in the chat, persona, trust posture).
  - **The calendar tools** — `mcp__claude_ai_Google_Calendar__*` from the
    account connector.
- `## Actions` (verbs; the install Action carries a checklist):
  - **Domo is installed** — the one-shot onboarding: walk Dependencies; interview
    the user (how do you want to use Domo? — tier-2 for named choices like
    solo/group, tier-3 for open answers like member names/persona); **author the
    user's custom Domo software** consulting `ref/`; run activation surfacing the
    code(s) to text; start the daemon; verify.
  - **Domo is activated** — the Plow handshake, documented in **both** shapes:
    - *Solo*: the activation shortcut (`POST /v1/auth/activate {provision_chat:true}`)
      → text one code → redeem → token + 1:1 chat.
    - *Group*: activate to get token + line → `POST /v1/chats` with
      `participants=[{agent,line_id},{member,display_name}…]` → each member texts
      their `VERIFY-XXXXXX` → `participant_verified` until all `active`.
  - **Domo runs** — background daemon; session resume; dev-channels confirmation
    via the PTY/expect driver.
  - **Domo replies / reads the calendar / reports activity** — runtime verbs
    (channel `reply`; calendar connector; transcript-feed logs).
- `## Verify` (read-only natural-language prompts; `ref/verify.sh` is the
  deterministic implementation):
  1. Tooling present (`bun`, `jq`, `expect`, `claude --version` ≥ 2.1.80).
  2. Subscription sign-in, **not** API key (`ANTHROPIC_API_KEY` unset; `claude`
     authenticated).
  3. Google Calendar connector tools available.
  4. The channel MCP server is registered; the daemon resumes the pinned session
     (`ref/domo doctor` / `status` green).
  5. Structural: the three SEED structural checks (README `## Purpose`; root
     `SEED.md` one-H1 + canonical grammar; tree-wide `SEED.md` conformance).
- `## Feedback`: `(none)` — privacy-by-default; Domo sends no install telemetry.
- `## Open`: briefing trigger (cron-injected morning message); launchd
  reboot-survival; per-sender gating (deferred — current trust posture is
  all-verified-members-equal).
- `## Non-Goals`: no `claude -p` (channels only); no API key; no shipped
  configurable product (the SEED authors bespoke software per user); non-macOS
  unsupported.

## README.md

`# Domo` + a marketing-readable `## Purpose` (the canonical back-reference
target). The existing operator guide becomes `## Usage` / `## Quickstart`,
pointing at the SEED install as the entry point. `## License` retained/added.

## Reference improvements (so `ref/` demonstrates both shapes)

- **`ref/channels/plow-chat/server.ts`** — tag inbound with
  `message.sender.display_name` instead of a hardcoded `"You"`, so a group
  reference shows real per-sender attribution. Solo still reads the user's name.
- **`ref/domo`** — rebase paths to run from `ref/` (above); keep the proven solo
  activation; add a **documented group-activation reference** (the
  `POST /v1/chats` member-creation + verification-poll pattern) so an authoring
  agent has a concrete group example. This is reference, not a shipped toggle.
- **`ref/verify.sh`** — deterministic implementation of the three SEED structural
  checks (optionally also invoking `ref/domo doctor`).

## Security invariants (MUST preserve)

- Plow **Bearer token**: user-wide; stored chmod-600 in `state.json`; never
  logged, printed, or committed. Activation secret passed via stdin, not argv.
- `ANTHROPIC_API_KEY` stays **unset** (subscription auth).
- Clone URLs and external clone commands: **no userinfo/query/fragment**
  (argv-exposure hygiene, per the SEED convention).
- SEED authoring: **no literal secret values** in `SEED.md` (describe the
  requirement, never the value).

## Build approach (workflow)

1. **Reorg** — `git mv` code → `ref/`, move `PLAN.md` → `docs/`, delete `run.sh`,
   rebase `ref/domo` paths, fix `.gitignore`. Verify `bash -n ref/domo` +
   `ref/domo status` runs clean.
2. **Author / improve (parallel, distinct files)** — `SEED.md`; `README.md`;
   `server.ts` attribution; `ref/verify.sh`; the group-activation reference.
3. **Review** — adversarial pass: SEED structural conformance, security
   invariants, `bash -n`, `ref/verify.sh`, path-rebase correctness.

No commits or pushes from inside the workflow; changes are reviewed and committed
after.
