# Purpose

> See [README#Purpose](README.md#purpose).

## Normative Language

The key words MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD NOT,
RECOMMENDED, MAY, and OPTIONAL in this document are to be interpreted as
described in RFC 2119. Sub-folder `SEED.md` files in this tree inherit this
declaration and MUST NOT re-declare it.

## Dependencies

`seed-domo` stands up one live, text-reachable Domo on the user's Mac. The
install is agent-driven: an installing agent reads this `SEED.md`, resolves one
concrete Domo home, bakes that absolute path into every generated artifact, and
then generates the runtime into that home. The checkout ships no product runtime
and no test harness; `ref/verify.sh` is the only committed runnable file.

Hard dependencies:

- **macOS** - Domo targets the user's local Mac.
- **Claude Code CLI** - `claude` MUST be on `PATH`.
- **Claude subscription auth** - Domo MUST use interactive Claude subscription
  auth in the baked `<HOME>/.claude`. `ANTHROPIC_API_KEY` and
  `CLAUDE_CODE_OAUTH_TOKEN` MUST be unset on all generated launch paths so Domo
  does not fall back to metered API billing or leaked ambient tokens.
- **claude.ai Google Calendar connector** - Google Calendar MUST be connected on
  the same Anthropic account used for Domo login.
- **Plow Chat API** - activation uses the real Plow API by default at
  `https://api.plow.co`; dev rehearsals bake the same generated code to a local
  Plow base URL.
- **`bun`** - runs generated TypeScript/Javascript helpers where the installing
  agent chooses that implementation.
- **`jq`** - performs strict JSON validation.
- **`curl`** - performs Plow HTTP calls.
- **`expect`** - answers Claude development-channel confirmations when needed.

The agent MUST surface missing hard dependencies early and stop on the first
missing dependency it cannot resolve.

### Baked Home Preflight

Before any generation, the installing agent resolves the install home:

1. Default user installs bake `<HOME>` to the absolute path `$HOME/.domo`.
2. Dev rehearsals MAY set a test home before generation, but the selected path
   is still baked into generated files. The runtime MUST NOT read `DOMO_HOME`.
3. The agent records the resolved path in `<HOME>/install-report.json` and uses
   the same literal path for all generated config, scripts, package metadata,
   logs, and status commands.
4. Generated operator commands MAY accept subcommands, but MUST derive their
   paths from literals written at generation time, not from environment
   variables.

## Objects

- **The installing agent** - the agent executing this SEED install action. It
  runs commands, generates files under the baked home, relays user actions in
  chat, polls status, and writes `install-report.json`.
- **The user** - the human installing Domo. The user performs only the human
  auth and texting steps: complete Claude login when asked, connect Google
  Calendar if needed, choose solo or group mode, and text the Plow activation or
  member verification messages.
- **Baked Domo home** - the concrete absolute install path. The default is
  `$HOME/.domo`, but once resolved it is referred to as `<HOME>` and MUST be
  embedded literally into generated artifacts. It is not a runtime setting.
- **Claude instance** - generated under `<HOME>/.claude`; owns isolated
  subscription login detection, first-run prompt immunity, and logout.
- **Calendar connector probe** - generated into `<HOME>/runtime/`; owns the
  Google Calendar connector check for the same Claude account.
- **Plow activation flow** - generated into `<HOME>/runtime/`; owns solo and
  group Plow activation and writes the Plow channel state.
- **Plow channel state** - `<HOME>/.claude/plow-chat/state.json`, written chmod
  600 with shape `{base_url, token, chat_uid}`. The token MUST never be printed,
  logged, committed, or passed in argv.
- **Domo runtime** - generated into `<HOME>/runtime/` and `<HOME>/bin/domo`;
  owns the workspace, daemon startup, readiness gate, status/logs/stop/reset
  commands, and the first outbound ready text.
- **The Domo workspace** - `<HOME>/workspace`, authored as a lean default
  `CLAUDE.md` for a solo or group household texting assistant with Calendar
  access.
- **The install dashboard** - `<HOME>/install-dashboard.html`, generated as a
  display-only, serverless monitor over `install-report.json`. It MAY show
  public copy-paste data such as the login command, Calendar connector URL, Plow
  activation message, and Plow target number. It MUST NOT contain secrets and
  MUST NOT drive orchestration.

## Actions

### Domo is installed

This action installs the current monolith as a spec-first generation. The
installing agent MUST generate the runtime into the baked `<HOME>` and MUST NOT
depend on committed product code under `ref/`.

Before generation, the agent resolves `<HOME>` per the baked-home preflight,
creates it if needed, and writes an initial `<HOME>/install-report.json` with
the resolved home and pending steps. For the default user install, `<HOME>` is
the absolute expansion of `$HOME/.domo`.

The agent SHOULD generate `<HOME>/install-dashboard.html` before the blocking
human steps when a browser is available. The dashboard is a soft gate: browser,
file open, or dashboard rendering failures are non-fatal. It is display-only,
uses meta refresh, and is regenerated from `install-report.json` after each
step. Terminal/chat output MUST provide the same install instructions if the
dashboard cannot be used.

The agent then generates and runs the install steps in this order:

1. **Login.** Generate an isolated Claude config under `<HOME>/.claude`, seed
   first-run prompt immunity, run the real Claude subscription login, and poll
   `claude auth status --json` until the four-field login truth holds:
   `rc==0`, `loggedIn==true`, `authMethod=="claude.ai"`, and
   `apiProvider=="firstParty"`.
2. **Calendar.** Prompt the user to connect Google Calendar at
   `https://claude.ai/customize/connectors`, then run a real in-session
   connector probe and require a strict `tool_use` to matching `tool_result`
   pair for `mcp__claude_ai_Google_Calendar__list_calendars`.
3. **Plow activation.** Ask whether this Domo is solo or group, defaulting to
   solo. Generate the activation flow. In solo mode, request activation with
   Plow chat provisioning, show the full `Plow Activate: <code>` message and
   target number, require the user to text the full message, poll redeem until
   verified, and write strict chmod-600 channel state. In group mode, verify
   the owner, create the group chat, reveal one-time member codes only after the
   listener is up, persist activation detail, and wait for all members plus
   `chat_active`. Bearer tokens MUST pass through stdin or chmod-600 temp files,
   never argv.
4. **Ready.** Generate `<HOME>/bin/domo`, the Domo workspace, the Plow MCP
   channel registration, the daemon launcher, and the readiness gate. Start the
   daemon on a pinned Claude session and send the first ready text only after a
   fresh post-snapshot `Channel notifications registered` log line appears for
   that pinned session.

If any step fails its verification, the agent MAY regenerate that step once and
rerun its verification. A second failure is terminal: the agent records
`failure` and the reason in `install-report.json` and stops without starting a
third attempt.

### Domo runs

The generated `<HOME>/bin/domo` command owns runtime operations. It MUST use
only baked absolute paths. Expected verbs include `start`, `stop`, `status`,
`logs`, `doctor`, and `reset`.

`reset` MUST call the generated Plow activation teardown for server-side chat
cleanup and the generated Claude instance logout for isolated auth cleanup
before removing the baked home behind safe path guards. It MUST NOT reimplement
either teardown inline.

### Domo replies, reads the calendar, and reports activity

User-visible replies MUST go through the Plow channel `reply` tool; transcript
output alone does not reach the chat. Calendar access MUST go through the
`mcp__claude_ai_Google_Calendar__*` connector tools. Logs and status output MUST
not contain the Plow Bearer token, activation secrets, or any metered API key.

## Verification

Verification is split by when a check can pass.

**Structural checks** hold on a fresh clone:

1. `README.md` contains a `## Purpose` H2 outside fenced code blocks.
2. Root `SEED.md` has exactly one `# Purpose`, follows the canonical H2 grammar,
   and includes `## Normative Language`.
3. Every `SEED.md` links its `# Purpose` body to the closest
   sibling-or-ancestor `README.md#purpose`.

The deterministic structural subset is implemented by:

```bash
bash ref/verify.sh
```

**Install rehearsal checks** hold only after a generated install is run against
the real protocol surfaces. In a user install, these checks run against the
user's real Claude account, real Google Calendar connector, and real Plow Chat
API. In a dev rehearsal, follow `docs/testing/e2e-rehearsal.md` to bake the
same generated runtime to the local Plow and DTU endpoints while still using a
real Claude login and real Calendar connector.

Required evidence:

1. The isolated Claude instance reports the four-field subscription login truth
   with metered API keys unset on the generated launch path.
2. The Calendar probe reports connected only from a real
   `tool_use`/`tool_result` match.
3. The activation flow shows the full `Plow Activate: <code>` message, rejects a
   bare code, writes strict chmod-600 Plow channel state, and never exposes the
   bearer token in argv, logs, or committed files.
4. The generated daemon accepts only a fresh readiness line for the pinned
   session, sends the first ready text through the Plow `reply` path, and leaves
   no runtime dependence on `DOMO_HOME`.
5. `<HOME>/install-report.json` records every step and
   `<HOME>/install-dashboard.html`, when generated, reflects those statuses
   without secrets.

## Feedback

(none)

## Open Items

- **Morning briefing trigger** - a scheduled morning message so Domo can
  proactively brief the household. Deferred.
- **Reboot survival** - a launchd job so the daemon survives a host reboot.
  Deferred.
- **Domo-specific authorization policy** - a future policy layer can narrow what
  verified chat members may ask Domo to do. The current solo install trusts the
  verified phone.

## Non-Goals

- **No shell flow orchestrator** - orchestration lives in this SEED action and is
  executed by the installing agent.
- **No committed product runtime** - runtime code is generated into the baked
  home at install time; the checkout ships only prose and `ref/verify.sh`.
- **No API key billing** - `ANTHROPIC_API_KEY` stays unset; Domo is
  subscription-billed and MUST NOT fall back to a metered key.
- **No non-macOS reference target** - non-macOS hosts are unsupported.
