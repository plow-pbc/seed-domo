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

- **macOS** - the reference ready piece uses the local macOS environment for the
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

## Objects

- **The installing agent** - the agent executing this SEED install action. It
  runs shell commands, relays user actions in chat, polls piece status, and keeps
  `DOMO_HOME=$HOME/.domo` threaded through every step.
- **The user** - the human installing Domo. The user performs only the human
  auth and texting steps: complete Claude login when asked, connect Google
  Calendar if needed, choose solo or group mode, and text the Plow activation or
  member verification messages.
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
- **Activation piece** - `ref/domo-activate-piece.sh`. It owns solo and group
  Plow activation and writes the Plow channel state.
- **Ready piece** - `ref/domo-ready-piece.sh`. It owns default Domo config,
  daemon startup, and the first outbound ready text.
- **Plow channel state** - `$DOMO_HOME/.claude/plow-chat/state.json`, written by
  the activation piece with chmod 600 and shape `{base_url, token, chat_uid}`.
  The token MUST never be printed, logged, committed, or passed in argv.
- **The Domo workspace** - `$DOMO_HOME/workspace`, authored by the ready piece
  with a lean default `CLAUDE.md` for a solo or group household texting
  assistant with Calendar access.
- **The Plow Chat channel** - `ref/channels/plow-chat`, an MCP stdio server with
  the `claude/channel` capability. It reads `PLOW_CHAT_STATE`; it MUST NOT
  hardcode secrets and MUST NOT log the Bearer token.
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
converted `claude-instance` and `calendar-connector` sub-SEED dependencies, then
run the remaining verified monolith pieces below in order against
`DOMO_HOME=$HOME/.domo`. The agent MUST NOT reimplement piece internals.

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

Before running the activation piece, the agent asks the user whether this Domo is
for a solo chat or a group chat. Solo is the default. For group mode, the agent
also asks for the household member display names and MUST include the installer
as one member. The agent passes the mode to the activation piece; it MUST NOT
edit Plow state by hand.

Who runs what:

- For solo, the agent starts real activation:

  ```bash
  DOMO_HOME=$HOME/.domo ref/domo-activate-piece.sh activate
  ```

- For group, the agent starts real activation with one or more member names:

  ```bash
  DOMO_HOME=$HOME/.domo ref/domo-activate-piece.sh activate --group "You" "Pat"
  ```

- The activation piece prints the full activation message and target number.
- For solo, the agent relays them to the user in chat in this form:

  ```text
  Text "Plow Activate: CODE" to NUMBER from the phone Domo should use.
  ```

- For group, the installer first texts the owner activation message. The piece
  then creates the group chat, prints one `VERIFY-XXXXXX` code per member, and
  the agent relays each member's own code and target number. Each member sends
  exactly their own verification code from their own phone.
- The activation piece continues polling Plow until redeem returns verified and
  then, for group mode, listens on Plow WSS until all members verify and
  `chat_active` arrives. It writes:

  ```text
  $DOMO_HOME/.claude/plow-chat/state.json
  ```

Done when the activation piece reports `VERIFIED` for solo or `VERIFIED_GROUP`
for group and the state file is present, chmod 600, and strictly shaped as
`{base_url, token, chat_uid}`. The agent MUST never print the token.

Dashboard updates:

While requesting activation:

```bash
ref/installer/client.sh installer_step activate active "Preparing text activation" || true
```

After the activation piece receives `MESSAGE` and `NUMBER` from Plow, it prints
them in terminal and best-effort pushes the same public copy-paste data to the
dashboard. `MESSAGE` is the full exact text to send, not the bare display code:

```bash
ref/installer/client.sh installer_step activate waiting "Text the activation message" || true
ref/installer/client.sh installer_verify "You" pending "MESSAGE" "NUMBER" self || true
```

For group mode, the activation piece also best-effort pushes one verification
row per member with that member's display name, `VERIFY-XXXXXX` code, and target
number. Each row flips to verified as the WSS `participant_verified` frame
arrives; the activation step becomes ok when `chat_active` arrives.

The dashboard MUST NOT receive activation secrets or the Plow Bearer token. It
MAY receive only the public one-time activation message and target number that
the user must text.

When verified:

```bash
ref/installer/client.sh installer_verify "You" verified "" "" self || true
ref/installer/client.sh installer_step activate ok "Text line activated" || true
ref/installer/client.sh installer_step ready active "Starting Domo" || true
```

**Step 4 - Ready.**

Who runs what:

- The agent runs:

  ```bash
  DOMO_HOME=$HOME/.domo ref/domo-ready-piece.sh ready
  ```

The ready piece authors the default solo or group Domo config based on
`$DOMO_HOME/install-state.json`, registers the Plow chat channel, starts the
background Claude daemon, and sends the deterministic first ready text through
the real Plow `reply` path to the activated chat.

Done when the ready piece reports the ready text was sent. The user should then
receive Domo's first text on the phone used in Step 3.

Dashboard updates:

Before running the ready piece:

```bash
ref/installer/client.sh installer_step ready active "Starting Domo" || true
```

When the ready text is sent:

```bash
ref/installer/client.sh installer_step ready ok "Domo is running" || true
ref/installer/client.sh installer_done "Domo is live - check your phone for the ready text." || true
```

### Domo is activated

Solo and group activation are owned by:

```bash
DOMO_HOME=$HOME/.domo ref/domo-activate-piece.sh activate
```

Solo performs:

1. `POST /v1/auth/activate` with `{"name":"Domo","provision_chat":true}`.
2. User texts the displayed full message (`Plow Activate: <display_code>`) to the
   displayed number.
3. Poll `POST /v1/auth/activate/redeem` until `status=verified`.
4. Write chmod-600 `{base_url, token, chat_uid}` state.

Group is invoked with:

```bash
DOMO_HOME=$HOME/.domo ref/domo-activate-piece.sh activate --group "You" "Pat"
```

It performs:

1. `POST /v1/auth/activate` without `provision_chat`.
2. Installer texts the displayed full owner activation message.
3. Poll `POST /v1/auth/activate/redeem` until `status=verified`.
4. `GET /v1/lines`.
5. `POST /v1/chats` with one agent participant and one member participant per
   supplied display name.
6. Persist each one-time member `verification_code` immediately in chmod-600
   `install-state.json` activation detail and surface it to that member.
7. Listen on Plow WSS for `participant_verified` frames and `chat_active`.
8. Write chmod-600 `{base_url, token, chat_uid}` state.

Activation secrets MUST pass through stdin or chmod-600 files, never command
arguments. Bearer tokens MUST be written chmod 600, never logged, never printed,
and never committed.

### Domo runs

Runtime startup is owned by:

```bash
DOMO_HOME=$HOME/.domo ref/domo-ready-piece.sh ready
```

The ready piece writes a lean default Domo config for the solo or group
household, starts the Claude Code daemon with the Plow chat channel loaded, and
sends the first ready text through the channel `reply` tool.
`ref/domo-ready-piece.sh status` prints non-secret readiness state.
`ref/domo-ready-piece.sh stop` stops the daemon and sweeps the channel child.

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

3. Activation and ready evidence is collected from a real install run: activation
   must show the full `Plow Activate: <code>` message and send-to number, a bare
   code must not verify, successful activation must write chmod-600
   `{base_url, token, chat_uid}` state, the channel server must connect and
   advertise `claude/channel` plus the `reply` tool, and the first ready text
   must land through the real Plow message path. Development checkouts MAY keep
   a private rehearsal overlay under ignored `docs/testing/`; that overlay is
   not part of the shipped SEED contract.

**Runtime checks** hold only after the install action completes:

1. The isolated Domo home is signed in to Claude subscription auth with
   `ANTHROPIC_API_KEY` unset.
2. Google Calendar is confirmed from inside that same isolated account.
3. Plow state exists at `$DOMO_HOME/.claude/plow-chat/state.json`, is chmod 600,
   and contains exactly `{base_url, token, chat_uid}`.
4. The ready piece has started the daemon and sent the first ready text to the
   activated phone.

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
