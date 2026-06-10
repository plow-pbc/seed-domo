# Purpose

> See [README#Purpose](README.md#purpose).

## Normative Language

The key words MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD NOT,
RECOMMENDED, MAY, and OPTIONAL in this document are to be interpreted as
described in RFC 2119. Sub-folder `SEED.md` files in this tree inherit this
declaration and MUST NOT re-declare it.

## Dependencies

`seed-domo` installs one live, text-reachable Domo on the user's Mac. The
installing agent performs a leaves-first walk: it first reads and verifies the
external Plow contract SEED, then installs each composed slice below, then runs
this root's union Verification against the same generated instance. The root
MUST NOT regenerate a slice during union Verification.

Hard dependencies, ordered hardware to accounts to software:

- **macOS** - the generated runtime targets the user's local Mac.
- **Claude subscription auth** - Domo uses Claude Code's `claude.ai`
  subscription login, never metered API-key billing.
- **claude.ai Google Calendar connector** - Google Calendar must be connected on
  the same Anthropic account used for Domo login.
- **Plow Chat API account** - activation uses the Plow Chat contract surfaced by
  `seed-plow-chat`.
- **Claude Code CLI** - `claude` MUST be on `PATH`.
- **`bun`** - used by the generated Plow channel server and direct MCP sender.
- **`jq`** - used for strict JSON checks.
- **`curl`** - used for Plow HTTP calls.
- **`expect`** - used by generated Claude TUI wrappers.
- **`tmux`** - used as the generated daemon's long-lived session owner.

Before slice 1, the installing agent MUST resolve the baked Domo home once,
defaulting to the absolute path for `$HOME/.domo` in a user install. That path is
an install constant carried into every slice generation. Generated entrypoints
MUST embed the concrete path and MUST NOT read a runtime `DOMO_HOME` variable.

Before slice 1, the installing agent MUST also create repo-root
`install-report.json` and generate `<HOME>/install-dashboard.html`. The dashboard
is a static display-only file, not a shipped server and not an orchestrator. It
MUST be regenerated from `install-report.json` as steps complete and MUST include:

- a step list with live statuses from `install-report.json`;
- copy-paste blocks for the generated Claude login command, the full
  `Plow Activate: <code>` string, and the send-to number;
- no bearer token, Claude token, API key, password, or secret;
- a meta-refresh tag so a browser reloads the regenerated file;
- the `file://` URL surfaced to the user when a browser can open it.

Dashboard generation, refresh, browser open, and `file://` surfacing are soft
gates. If any dashboard step fails or no browser is available, the install MUST
continue through terminal/chat fallback and `install-report.json` remains the
canonical progress record.

First, the external Plow API contract SEED is cloned, audited, and verified. It
is the single declaring site for the Plow API surface consumed by Domo:

- [seed-plow-chat](https://github.com/plow-pbc/seed-plow-chat) - Plow Chat API
  contract.

Then the composed slices are installed leaves-first in this order:

1. [Purpose](seeds/claude-instance/SEED.md#purpose)
2. [Purpose](seeds/calendar-connector/SEED.md#purpose)
3. [Purpose](seeds/plow-channel-server/SEED.md#purpose)
4. [Purpose](seeds/plow-activation/SEED.md#purpose)
5. [Purpose](seeds/domo-runtime/SEED.md#purpose)

## Objects

- **Installing agent** - the agent executing this SEED. It resolves the baked
  home, creates `install-report.json`, generates the static install dashboard,
  installs slices leaves-first, records evidence, and surfaces user actions.
- **User** - the human installer. The user completes Claude login, connects
  Google Calendar if needed, texts the surfaced Plow activation or member
  verification messages, and confirms the final Domo reply.
- **Baked Domo home** - the absolute install home selected before slice
  generation. User installs default to `$HOME/.domo`. Generated files contain
  this path as a literal.
- **`install-report.json`** - the repo-root progress and evidence record for the
  current install. It records each dependency and slice status, terminal failures,
  non-secret user-action values, and union Verification evidence.
- **Install dashboard** - `<HOME>/install-dashboard.html`, generated at install
  time from `install-report.json`. It is display-only, meta-refreshed, and may
  show only non-secret copy-paste values.
- **Claude instance slice** - `seeds/claude-instance/SEED.md`, owner of isolated
  Claude subscription auth, first-run prompt immunity, metered-key-unset launch
  discipline, and logout helper.
- **Calendar connector slice** - `seeds/calendar-connector/SEED.md`, owner of the
  real Google Calendar connector probe and strict transcript parser.
- **Plow channel server slice** - `seeds/plow-channel-server/SEED.md`, owner of
  the generated MCP channel server, `claude/channel` capability, `reply` tool,
  inbound notification delivery, WebSocket liveness, and token-redaction
  discipline for its surface.
- **Plow activation slice** - `seeds/plow-activation/SEED.md`, owner of
  solo/group election, Plow activation helpers, local Plow state, install state,
  and server-side chat teardown usage.
- **Domo runtime slice** - `seeds/domo-runtime/SEED.md`, owner of workspace
  authoring, channel registration, pinned-session daemon startup, readiness
  gating, the first ready text, operator CLI, status/logs/stop/doctor, and reset
  delegation.
- **Plow channel state** - `<HOME>/.claude/plow-chat/state.json`, chmod 600,
  exactly `{base_url, token, chat_uid}`. The token MUST never be printed, logged,
  committed, surfaced in the dashboard, or passed in argv.
- **Domo workspace** - `<HOME>/workspace`, authored by the generated runtime with
  solo or group household instructions and Calendar access.
- **Operator CLI** - `<HOME>/bin/domo`, the generated user entrypoint containing
  only baked dispatch paths.

## Actions

### Domo is installed

1. Resolve the baked Domo home to a concrete absolute path before recursing into
   slices. Carry this value as install context for every slice generation.
2. Initialize repo-root `install-report.json` with pending records for the Plow
   contract, all five slices, dashboard generation, and root union Verification.
3. Generate `<HOME>/install-dashboard.html` from `install-report.json` before
   slice 1. Surface its `file://` URL when possible. Treat all dashboard failures
   as non-fatal and continue with terminal/chat fallback.
4. Clone, audit, and verify `https://github.com/plow-pbc/seed-plow-chat`. Record
   the clone path and commit in `install-report.json`.
5. Install the five sub-SEEDs in the order listed in `## Dependencies`. Each
   slice receives the same baked home. Each slice owns its own generation,
   regenerate-once policy, Verification, and terminal failure recording.
6. If a sub-SEED reaches terminal `failure`, stop the install walk. Do not
   regenerate from the root. Keep the partial state and failure reason visible in
   `install-report.json` and the generated dashboard if available.
7. After all slices pass, run this root's union Verification against the just
   generated instance. The root union is non-regenerating.

### Domo is activated

Activation is delegated to the generated Plow activation slice. The installing
agent relays only non-secret text instructions: the full
`Plow Activate: <code>` string, the send-to number, and any member `VERIFY-`
codes. The root MUST NOT duplicate solo/group election logic, edit Plow state by
hand, or surface the bearer token.

### Domo runs

Runtime startup is delegated to `<HOME>/bin/domo ready`. The generated runtime
authors the workspace, registers the Plow chat channel, starts Claude on the
pinned session, accepts readiness only from the host MCP log registration line
for that session, and sends the first ready text through the channel `reply` tool
after readiness.

### Domo replies and reads the calendar

User-visible replies MUST go through the Plow channel `reply` tool. Calendar
access MUST go through the claude.ai Google Calendar connector tools. Status,
logs, dashboard text, install evidence, and committed files MUST NOT contain the
Plow bearer token, activation secrets, Claude auth tokens, or metered API keys.

## Verification

Verification runs against the instance just produced by the install walk. It is
the live-operator union of the slice Verifications plus structural checks; it
MUST NOT regenerate slices or build a second instance.

1. Structural conformance passes:

   ```bash
   bash ref/verify.sh
   ```

   The repo's shipped `ref/` directory contains exactly `verify.sh` and no old
   product scripts, installer SPA/server, channel server, bin helper, harness, or
   test double.

2. `install-report.json` exists at the repo root, not under `<HOME>`, and records
   non-secret statuses for the Plow contract, all five slices, dashboard
   generation, and root union Verification.

3. `<HOME>/install-dashboard.html` exists when the soft gate can generate it. It
   reflects the statuses in `install-report.json`, contains a meta-refresh tag,
   contains the copy-paste login command, contains the full `Plow Activate:
   <code>` string and send-to number when activation is waiting, and contains no
   token, password, API key, bearer value, or secret-looking credential. If the
   dashboard could not be generated or opened, `install-report.json` records the
   non-fatal fallback and the same copy-paste values are surfaced in
   terminal/chat.

4. Claude instance seam: the generated isolated config is logged in with
   `rc == 0`, `loggedIn == true`, `authMethod == "claude.ai"`, and
   `apiProvider == "firstParty"`; generated Claude launch paths unset
   `ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN`; first-run immunity config
   is present and private.

5. Calendar seam: the generated Calendar check reports `CONNECTED` only from a
   real strict `tool_use` to matching `tool_result` `tool_use_id` pair for the
   Google Calendar connector, and a text-only transcript remains `PENDING`.

6. Plow channel seam: the generated MCP channel server is installed where
   `domo-runtime` consumes it, secret state is chmod 600, the real generated
   operator starts and stays green through `status --assert`, a real `reply`
   lands in the Plow chat with `status == "sent"`, and token hygiene is clean.

7. Plow activation seam: activation surfaces the full `Plow Activate: <code>`
   string and send-to number, a bare code does not verify, group mode verifies
   owner and members without rotating preserved codes on restart, activation
   writes strict chmod-600 `{base_url, token, chat_uid}` state, and cleanup invokes
   the contract's server-side chat teardown.

8. Runtime seam: `<HOME>/bin/domo` contains only baked dispatch paths; readiness
   is accepted only after a post-snapshot host MCP log line proves
   `Channel notifications registered` for the pinned session; the first ready
   text is sent only after readiness; `status` and `doctor` are green and
   non-secret; `reset` delegates to the generated Plow cleanup and Claude logout
   helpers instead of re-implementing either.

9. End-to-end operator check: Domo texts the activated phone with the ready text,
   receives one inbound user message, and sends a user-visible reply through the
   Plow `reply` tool. This is the final live user-install E2E.

## Feedback

(none)

## Open Items

- **Morning briefing trigger** - a scheduled morning message so Domo can
  proactively brief the household. Deferred.
- **Reboot survival** - a launchd job so the daemon survives a host reboot.
  Deferred.
- **Domo-specific authorization policy** - a future policy layer can narrow what
  verified chat members may ask Domo to do. The current install trusts verified
  chat participants.

## Non-Goals

- **No shell flow orchestrator** - orchestration lives in this SEED action and is
  executed by the installing agent.
- **No API key billing** - `ANTHROPIC_API_KEY` stays unset; Domo is
  subscription-billed and MUST NOT fall back to a metered key.
- **No non-macOS reference target** - non-macOS hosts are unsupported.
