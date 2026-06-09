# Purpose

> See [README#Purpose](README.md#purpose).

## Normative Language

The key words MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD NOT,
RECOMMENDED, MAY, and OPTIONAL in this document are to be interpreted as
described in RFC 2119. Sub-folder `SEED.md` files in this tree inherit this
declaration and MUST NOT re-declare it.

## Dependencies

`seed-domo` stands up one live, text-reachable Domo on the user's Mac. The
install action is agent-driven: an installing agent reads this `SEED.md`, walks
converted sub-SEED dependencies first, and runs the remaining verified monolith
pieces in `ref/` against the dedicated persistent `DOMO_HOME=$HOME/.domo`. In
the current partial conversion, `DOMO_HOME` is still the install-time home
substitution input for unconverted monolith pieces; converted sub-SEEDs bake the
resolved absolute path inside generated runtime artifacts.

Hard dependencies:

- **macOS** - the generated runtime uses the local macOS environment for the
  Claude Code daemon.
- **Claude Code CLI** - `claude` MUST be on `PATH`.
- **Claude subscription auth** - Domo MUST use interactive Claude subscription
  auth in `$DOMO_HOME/.claude`. `ANTHROPIC_API_KEY` and
  `CLAUDE_CODE_OAUTH_TOKEN` MUST be unset for the piece invocations so Domo does
  not fall back to metered API billing or leaked ambient tokens.
- **claude.ai Google Calendar connector** - Google Calendar MUST be connected on
  the same Anthropic account used for Domo login.
- **Plow Chat API** - activation uses the real Plow API by default at
  `https://api.plow.co`.
- **`bun`** - runs the Plow chat channel server.
- **`jq`** - performs strict JSON validation.
- **`curl`** - performs Plow HTTP calls.
- **`expect`** - answers the Claude development-channel confirmation for the
  background daemon.

The agent MUST surface missing hard dependencies early and stop on the first
missing dependency it cannot resolve.

Converted composed slices are installed before the remaining monolith actions:

1. [Purpose](seeds/claude-instance/SEED.md#purpose)
2. [Purpose](seeds/calendar-connector/SEED.md#purpose)
3. [Purpose](seeds/plow-activation/SEED.md#purpose)
4. [Purpose](seeds/domo-runtime/SEED.md#purpose)

## Objects

- **The installing agent** - the agent executing this SEED install action. It
  runs shell commands, relays user actions in chat, polls piece status, and keeps
  `DOMO_HOME=$HOME/.domo` threaded through every step.
- **The user** - the human installing Domo. The user performs only the human
  auth and texting steps: complete Claude login when asked, connect Google
  Calendar if needed, and text the Plow activation or member verification
  messages surfaced by the generated activation helper.
- **`DOMO_HOME`** - the dedicated persistent Domo home for the current monolith:
  `$HOME/.domo`. The agent MUST set and use exactly `DOMO_HOME=$HOME/.domo` for
  every piece command. The agent MUST NOT use the SEED checkout, any path inside
  the SEED checkout, or a temp directory as `DOMO_HOME`. The isolated Claude
  config is `$DOMO_HOME/.claude`. This is the current representation of the
  resolved home; generated runtime artifacts in later conversion chunks MUST
  bake the resolved absolute path instead of reading `DOMO_HOME` at runtime.
- **Claude instance sub-SEED** - `seeds/claude-instance/SEED.md`. It owns
  isolated Claude subscription login, the generated login/auth-status/logout
  helpers under `$DOMO_HOME/runtime/claude-instance`, metered-key-unset launch
  discipline, and seeded first-run prompt immunity under `$DOMO_HOME/.claude`.
- **Calendar connector sub-SEED** - `seeds/calendar-connector/SEED.md`. It owns
  the generated Calendar connector probe and strict stream-json transcript
  parser under `$DOMO_HOME/runtime/calendar-connector`.
- **Plow activation sub-SEED** - `seeds/plow-activation/SEED.md`. It owns the
  generated Plow activation helpers under
  `$DOMO_HOME/runtime/plow-activation`, the solo/group election, the local Plow
  channel state, and server-side chat teardown.
- **Plow channel server sub-SEED** - `seeds/plow-channel-server/SEED.md`. It
  owns the generated MCP channel server under
  `$DOMO_HOME/runtime/plow-channel-server`, the `claude/channel` capability,
  the `reply` tool, inbound notification delivery, WebSocket liveness,
  backfill/dedup state, and token-redaction discipline for its surface.
- **Domo runtime sub-SEED** - `seeds/domo-runtime/SEED.md`. It owns the
  generated runtime helpers under `$DOMO_HOME/runtime/domo-runtime`, the
  generated operator CLI at `$DOMO_HOME/bin/domo`, workspace authoring,
  channel registration, pinned-session daemon startup, readiness gating, the
  first outbound ready text, status/logs/stop/doctor, and reset delegation.
- **Plow channel state** - `$DOMO_HOME/.claude/plow-chat/state.json`, written by
  the generated Plow activation helper with chmod 600 and shape
  `{base_url, token, chat_uid}`. The token MUST never be printed, logged,
  committed, or passed in argv.
- **The Domo workspace** - `$DOMO_HOME/workspace`, authored by the generated
  runtime with a lean default `CLAUDE.md` for a solo or group household texting
  assistant with Calendar access.
- **The Plow Chat channel** - `$DOMO_HOME/runtime/plow-channel-server`, a
  generated MCP stdio channel server with the `claude/channel` capability and
  `reply` tool. It reads the baked state path
  `$DOMO_HOME/.claude/plow-chat/state.json`; it MUST NOT hardcode secrets, use
  runtime state-path environment seams, or log the Bearer token.
- **The install dashboard** - `ref/installer/`, a display-only local monitor
  served from `127.0.0.1`. The dashboard is a soft gate and a user-facing status
  surface only: it has no forms, accepts no install input from the user, and MUST
  NOT drive orchestration. The installing agent owns all dashboard state updates
  through `ref/installer/client.sh`. The dashboard state MUST NOT contain
  secrets; it MAY show public user-action data such as the login command,
  Calendar connector URL, Plow activation message, and Plow target number.

## Actions

### Domo is installed

This action installs the Domo slice. The installing agent MUST first install the
converted `claude-instance`, `calendar-connector`, `plow-activation`,
`plow-channel-server`, and `domo-runtime` sub-SEED dependencies, then run the
generated helpers below in order against `DOMO_HOME=$HOME/.domo`. The agent
MUST NOT reimplement sub-SEED internals.

Before starting, the agent sets the fixed install home and shows it:

```bash
export DOMO_HOME="$HOME/.domo"
```

All commands below MUST use that same `DOMO_HOME`. The agent MUST NOT substitute
the SEED repo path or a temp directory. For dev rehearsals, the overlay may
choose a different concrete home before this point; once chosen, the same value
is used for the whole monolith install.

**Phase 0 - Display-only dashboard.**

The agent SHOULD launch the dashboard when a browser is available. This is a
soft gate: if the server, browser, or open command is unavailable, the install
continues in the agent chat and terminal with the same piece commands.
Every dashboard command is best-effort. The agent MUST treat any dashboard
launch, URL lookup, browser open, or state push failure as non-fatal, ignore that
dashboard failure for install control flow, and continue with the terminal/chat
fallback.

The dashboard is the user's primary simple progress monitor and copy-paste
surface. It is display-only; the user does not click dashboard controls to drive
install progress. The user acts in their terminal, browser, and phone.

The agent initializes one dashboard state directory scoped to `DOMO_HOME`:

```bash
export INSTALLER_STATE_DIR="$DOMO_HOME/installer-ui"
INSTALLER_NO_OPEN=1 ref/installer/start.sh || true
ref/installer/client.sh installer_reset "Setting up Domo" || true
ref/installer/client.sh installer_set subtitle "Follow the current action below. This page updates automatically." || true
ref/installer/client.sh installer_step login pending "Sign in to Claude" || true
ref/installer/client.sh installer_step calendar pending "Connect Google Calendar" || true
ref/installer/client.sh installer_step activate pending "Activate Domo by text" || true
ref/installer/client.sh installer_step ready pending "Start Domo" || true
```

If a browser can be opened, the agent opens the local dashboard URL:

```bash
url="$(ref/installer/client.sh installer_url 2>/dev/null)" && open "$url" || true
```

If no browser is available, the agent prints the same progress in terminal/chat
and continues. The dashboard server is a monitor only; failure to launch or
update it MUST NOT block the four verified pieces.

**Step 1 - Login.**

Login is owned by the `claude-instance` sub-SEED installed before this root
action. The installing agent MUST NOT run `ref/domo-login-piece.sh` as the root
login step. Instead, it uses the generated login and auth-status helpers from:

```text
$DOMO_HOME/runtime/claude-instance
```

Who runs what:

- The agent pushes the login step as `waiting`; this is the dashboard's
  "Watching" state. The agent MUST NOT push this state until it is ready to
  start or verify the sub-SEED login below:

  ```bash
  ref/installer/client.sh installer_step login waiting "Sign in to Claude" terminal "$DOMO_HOME/runtime/claude-instance/login" || true
  ```

- If the sub-SEED auth-status helper does not already confirm subscription
  auth, the agent tells the user to run the generated login command in their own
  terminal:

  ```bash
  $DOMO_HOME/runtime/claude-instance/login
  ```

- The user completes the browser-based Claude subscription login.
- After relaying the login command, the agent runs the generated auth-status
  wait while the dashboard remains in the `waiting` state. The wait polls until
  the isolated Claude subscription auth is confirmed:

  ```bash
  $DOMO_HOME/runtime/claude-instance/auth-status
  ```

Done when the auth-status helper exits 0 and proves
`rc==0 && loggedIn==true && authMethod=="claude.ai" &&
apiProvider=="firstParty"`. If it times out or exits nonzero, the agent
surfaces the failure. The agent MUST NOT ask for, print, or copy Claude auth
tokens.

When the blocking wait exits 0:

```bash
ref/installer/client.sh installer_step login ok "Signed in to Claude" || true
```

**Step 2 - Calendar.**

Calendar is owned by the `calendar-connector` sub-SEED installed before this
root action. The installing agent MUST NOT run `ref/domo-calendar-piece.sh` as
the root Calendar step. Instead, it uses the generated check and wait helpers
from:

```text
$DOMO_HOME/runtime/calendar-connector
```

Who runs what:

- The agent pushes the Calendar step as `waiting`; this is the dashboard's
  "Watching" state. The agent MUST NOT push this state until it is ready to
  start the blocking wait below:

  ```bash
  ref/installer/client.sh installer_step calendar waiting "Connect Google Calendar" browser "https://claude.ai/customize/connectors" || true
  ```

- The agent tells the user to connect Google Calendar for the same Anthropic
  account at:

  ```text
  https://claude.ai/customize/connectors
  ```

- After relaying the connector action, the agent runs the blocking Calendar wait
  while the dashboard remains in the `waiting` state. The generated wait helper
  repeatedly probes the connector until it is confirmed:

  ```bash
  $DOMO_HOME/runtime/calendar-connector/wait
  ```

Done when the wait command exits 0 after reporting `CONNECTED`. The agent MUST
NOT wait for the user to say the connector is done and MUST NOT mark Calendar
complete from user assertion alone.

When the blocking wait exits 0:

```bash
ref/installer/client.sh installer_step calendar ok "Google Calendar connected" || true
ref/installer/client.sh installer_step activate active "Preparing text activation" || true
```

**Step 3 - Plow activation.**

Plow activation is owned by the `plow-activation` sub-SEED installed before this
root action. The installing agent MUST NOT run `ref/domo-activate-piece.sh` as
the root activation step. Instead, it uses the generated helpers from:

```text
$DOMO_HOME/runtime/plow-activation
```

Solo/group election and any household member-name collection are owned by that
sub-SEED and its generated helper. The root action MUST NOT duplicate the
election logic or edit Plow state by hand.

Who runs what:

- The agent runs the generated activation helper according to the
  `plow-activation` sub-SEED's election result. For solo, the generated command
  is:

  ```bash
  $DOMO_HOME/runtime/plow-activation/activate --solo
  ```

- For group, the generated command includes one or more member display names as
  defined by the sub-SEED election:

  ```bash
  $DOMO_HOME/runtime/plow-activation/activate --group "You" "Pat"
  ```

- The generated activation helper prints the full activation message and target
  number.
- For solo, the agent relays them to the user in chat in this form:

  ```text
  Text "Plow Activate: CODE" to NUMBER from the phone Domo should use.
  ```

- For group, the installer first texts the owner activation message. The
  generated helper then creates the group chat, prints one `VERIFY-XXXXXX` code
  per member after its WebSocket listener is up, and the agent relays each
  member's own code and target number. Each member sends exactly their own
  verification code from their own phone.
- The generated activation helper continues polling Plow until redeem returns
  verified and then, for group mode, listens until all members verify and the
  chat becomes active. It writes:

  ```text
  $DOMO_HOME/.claude/plow-chat/state.json
  ```

Done when the generated activation helper exits 0 and the state file is
present, chmod 600, and strictly shaped as `{base_url, token, chat_uid}`. The
agent MUST never print the token.

Dashboard updates:

While requesting activation:

```bash
ref/installer/client.sh installer_step activate active "Preparing text activation" || true
```

After the generated activation helper receives `MESSAGE` and `NUMBER` from
Plow, it prints them in terminal and best-effort pushes the same public
copy-paste data to the dashboard. `MESSAGE` is the full exact text to send, not
the bare display code:

```bash
ref/installer/client.sh installer_step activate waiting "Text the activation message" || true
ref/installer/client.sh installer_verify "You" pending "MESSAGE" "NUMBER" self || true
```

For group mode, the generated helper also best-effort pushes one verification
row per member with that member's display name, `VERIFY-XXXXXX` code, and target
number. Each row flips to verified as participant verification is observed; the
activation step becomes ok when the chat becomes active.

The dashboard MUST NOT receive activation secrets or the Plow Bearer token. It
MAY receive only the public one-time activation message and target number that
the user must text.

When verified:

```bash
ref/installer/client.sh installer_verify "You" verified "" "" self || true
ref/installer/client.sh installer_step activate ok "Text line activated" || true
ref/installer/client.sh installer_step ready active "Starting Domo" || true
```

**Step 4 - Runtime ready.**

Who runs what:

- The agent runs:

  ```bash
  $DOMO_HOME/bin/domo ready
  ```

The generated runtime authors the default solo or group Domo config based on
`$DOMO_HOME/install-state.json`, registers the Plow chat channel, starts the
background Claude daemon on the pinned session, accepts readiness only after a
post-snapshot host MCP log line proves
`Channel notifications registered` for that pinned session, and then sends the
deterministic first ready text through the real Plow `reply` path to the
activated chat.

Done when `$DOMO_HOME/bin/domo ready` exits 0 after host-log readiness and the
ready text is sent. The user should then receive Domo's first text on the phone
used in Step 3.

Dashboard updates:

Before running the generated runtime:

```bash
ref/installer/client.sh installer_step ready active "Starting Domo" || true
```

When the ready text is sent:

```bash
ref/installer/client.sh installer_step ready ok "Domo is running" || true
ref/installer/client.sh installer_done "Domo is live - check your phone for the ready text." || true
```

### Domo is activated

Solo and group activation are owned by the `plow-activation` sub-SEED and its
generated helpers:

```text
$DOMO_HOME/runtime/plow-activation/activate
```

The generated activation helper performs the contract-defined Plow calls by
reading `seed-plow-chat`. This root SEED carries only the root-level delegation:
run the generated helper, relay the public text instructions, verify the local
state file, and never print the token.

Activation secrets MUST pass through stdin or chmod-600 files, never command
arguments. Bearer tokens MUST be written chmod 600, never logged, never printed,
and never committed. Server-side chat teardown is also delegated to the
generated `cleanup` helper from this sub-SEED.

### Domo runs

Runtime startup is owned by the `domo-runtime` sub-SEED and its generated
operator CLI:

```bash
$DOMO_HOME/bin/domo ready
```

The generated runtime writes a lean default Domo config for the solo or group
household, starts the Claude Code daemon with the Plow chat channel loaded,
gates readiness on the host MCP log registration line for the pinned session,
and sends the first ready text through the channel `reply` tool only after that
gate passes. `$DOMO_HOME/bin/domo status` prints non-secret readiness state,
`$DOMO_HOME/bin/domo logs` renders transcript or stripped raw logs, and
`$DOMO_HOME/bin/domo stop` stops the daemon and sweeps the channel child.

### Domo replies / reads the calendar / reports activity

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

**Piece checks** hold when dependencies are present:

1. The `claude-instance` sub-SEED verification confirms subscription auth:

   - `claude auth status --json` under `$DOMO_HOME/.claude` returns
     `rc==0`, `loggedIn==true`, `authMethod=="claude.ai"`, and
     `apiProvider=="firstParty"`;
   - generated launch paths unset `ANTHROPIC_API_KEY` and
     `CLAUDE_CODE_OAUTH_TOKEN`;
   - `$DOMO_HOME/.claude/.claude.json` and `$DOMO_HOME/.claude/settings.json`
     are chmod 600 and contain the first-run prompt immunity flags.

2. The `calendar-connector` sub-SEED verification confirms the connector:

   - generated runtime helpers exist under
     `$DOMO_HOME/runtime/calendar-connector`;
   - generated Claude launch paths unset `ANTHROPIC_API_KEY` and
     `CLAUDE_CODE_OAUTH_TOKEN`;
   - `check` reports `CONNECTED` only from a strict
     `tool_use` -> `tool_result` match by `tool_use_id` against the real
     Google Calendar connector;
   - the generated text-only transcript fixture parses as `PENDING`.

3. The `plow-activation` sub-SEED verification confirms activation:

   - generated runtime helpers exist under
     `$DOMO_HOME/runtime/plow-activation`;
   - solo activation shows the full `Plow Activate: <code>` message and send-to
     number, and a bare code does not verify;
   - group activation verifies owner and members, reveals member codes only
     after the listener is up, and restart resumes without rotating codes;
   - successful activation writes chmod-600 `{base_url, token, chat_uid}` state;
   - cleanup invokes server-side chat teardown and removes local Plow state.

4. The `plow-channel-server` sub-SEED verification confirms channel behavior:

   - generated channel interface exists under
     `$DOMO_HOME/runtime/plow-channel-server`;
   - generated `.mcp.json` registers `plow-chat` from that generated channel
     directory;
   - it advertises `claude/channel` and the `reply` tool;
   - WebSocket connection writes the non-secret connected marker;
   - `reply` lands through the real Plow message path;
   - restart backfill does not replay historical inbound messages;
   - repeated inbound messages are de-duplicated with chmod-600
     `last_seen.json`;
   - malformed or absent state never crashes the MCP transport;
   - display names are sanitized before channel delivery;
   - no Bearer token appears in logs, argv, committed files, or rehearsal logs.

5. The `domo-runtime` sub-SEED verification confirms runtime readiness:

   - generated runtime helpers exist under `$DOMO_HOME/runtime/domo-runtime`;
   - generated `$DOMO_HOME/bin/domo` contains baked absolute paths only and does
     not read `DOMO_HOME`;
   - the readiness gate accepts only a post-snapshot
     `Channel notifications registered` host-log line for the pinned session
     and rejects stale, other-session, and `skipped` lines;
   - the first ready text is sent only after readiness and lands through the
     real Plow message path;
   - reset invokes the generated Plow cleanup helper and generated Claude logout
     helper instead of re-implementing either teardown.

**Runtime checks** hold only after the install action completes:

1. The isolated Domo home is signed in to Claude subscription auth with
   `ANTHROPIC_API_KEY` unset.
2. Google Calendar is confirmed from inside that same isolated account.
3. Plow state exists at `$DOMO_HOME/.claude/plow-chat/state.json`, is chmod 600,
   and contains exactly `{base_url, token, chat_uid}`.
4. The generated runtime has started the daemon, proved pinned-session host
   channel registration, and sent the first ready text to the activated phone.

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
- **No API key billing** - `ANTHROPIC_API_KEY` stays unset; Domo is
  subscription-billed and MUST NOT fall back to a metered key.
- **No non-macOS reference target** - non-macOS hosts are unsupported.
