# Purpose

> See [README#Purpose](README.md#purpose).

## Normative Language

The key words MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD NOT,
RECOMMENDED, MAY, and OPTIONAL in this document are to be interpreted as
described in RFC 2119. Sub-folder `SEED.md` files in this tree inherit this
declaration and MUST NOT re-declare it.

## Dependencies

`seed-domo` stands up one live, text-reachable Domo on the user's Mac. The
install action is agent-driven: an installing agent reads this `SEED.md` and runs
the verified piece scripts in `ref/` against the dedicated persistent
`DOMO_HOME=$HOME/.domo`.

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
- **Plow Chat API** - solo activation uses the real Plow API by default at
  `https://api.plow.co`.
- **`bun`** - runs the Plow chat channel server and piece selftests.
- **`jq`** - performs strict JSON validation.
- **`curl`** - performs Plow HTTP calls.
- **`expect`** - answers the Claude development-channel confirmation for the
  background daemon.

The agent MUST surface missing hard dependencies early and stop on the first
missing dependency it cannot resolve.

## Objects

- **The installing agent** - the agent executing this SEED install action. It
  runs shell commands, relays user actions in chat, polls piece status, and keeps
  `DOMO_HOME=$HOME/.domo` threaded through every step.
- **The user** - the human installing Domo. The user performs only the human
  auth and texting steps: complete Claude login when asked, connect Google
  Calendar if needed, and text one Plow activation code.
- **`DOMO_HOME`** - the dedicated persistent Domo home for the install:
  `$HOME/.domo`. The agent MUST set and use exactly `DOMO_HOME=$HOME/.domo` for
  every piece command. The agent MUST NOT use the SEED checkout, any path inside
  the SEED checkout, or a temp directory as `DOMO_HOME`. The isolated Claude
  config is `$DOMO_HOME/.claude`.
- **Login piece** - `ref/domo-login-piece.sh`. It owns isolated Claude
  subscription login detection.
- **Calendar piece** - `ref/domo-calendar-piece.sh`. It owns the Google Calendar
  connector probe.
- **Activation piece** - `ref/domo-activate-piece.sh`. It owns solo Plow
  activation and writes the Plow channel state.
- **Ready piece** - `ref/domo-ready-piece.sh`. It owns default Domo config,
  daemon startup, and the first outbound ready text.
- **Plow channel state** - `$DOMO_HOME/.claude/plow-chat/state.json`, written by
  the activation piece with chmod 600 and shape `{base_url, token, chat_uid}`.
  The token MUST never be printed, logged, committed, or passed in argv.
- **The Domo workspace** - `$DOMO_HOME/workspace`, authored by the ready piece
  with a lean default `CLAUDE.md` for a solo household texting assistant with
  Calendar access.
- **The Plow Chat channel** - `ref/channels/plow-chat`, an MCP stdio server with
  the `claude/channel` capability. It reads `PLOW_CHAT_STATE`; it MUST NOT
  hardcode secrets and MUST NOT log the Bearer token.
- **The install dashboard** - `ref/installer/`, a display-only local monitor
  served from `127.0.0.1`. The dashboard is a soft gate and a user-facing status
  surface only: it has no forms, accepts no install input from the user, and MUST
  NOT drive orchestration. The installing agent owns all dashboard state updates
  through `ref/installer/client.sh`. The dashboard state MUST NOT contain
  secrets; it MAY show public user-action data such as the login command,
  Calendar connector URL, Plow activation code, and Plow target number.

## Actions

### Domo is installed

This action installs the solo Domo slice. The installing agent MUST run the four
verified pieces below in order against `DOMO_HOME=$HOME/.domo`. The agent MUST
NOT reimplement piece internals.

Before starting, the agent sets the fixed install home and shows it:

```bash
export DOMO_HOME="$HOME/.domo"
```

All commands below MUST use that same `DOMO_HOME`. The agent MUST NOT substitute
the SEED repo path or a temp directory.

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

Who runs what:

- The agent tells the user to run this command in their own terminal:

  ```bash
  DOMO_HOME=$HOME/.domo ref/domo-login-piece.sh login
  ```

- The user completes the browser-based Claude subscription login.
- The agent polls until login is confirmed:

  ```bash
  DOMO_HOME=$HOME/.domo ref/domo-login-piece.sh status
  ```

Done when the status output reports `CONFIRMED`. If status is not confirmed, the
agent waits and retries. The agent MUST NOT ask for, print, or copy Claude auth
tokens.

Dashboard updates:

```bash
ref/installer/client.sh installer_step login waiting "Sign in to Claude" terminal "DOMO_HOME=$HOME/.domo ref/domo-login-piece.sh login" || true
```

When confirmed:

```bash
ref/installer/client.sh installer_step login ok "Signed in to Claude" || true
ref/installer/client.sh installer_step calendar active "Checking Google Calendar" || true
```

**Step 2 - Calendar.**

Who runs what:

- The agent probes the connector:

  ```bash
  DOMO_HOME=$HOME/.domo ref/domo-calendar-piece.sh check
  ```

- If the result is `CONNECTED`, continue.
- If the result is `NOT_CONNECTED`, the agent tells the user to connect Google
  Calendar for the same Anthropic account at:

  ```text
  https://claude.ai/customize/connectors
  ```

- After the user says it is connected, the agent re-runs:

  ```bash
  DOMO_HOME=$HOME/.domo ref/domo-calendar-piece.sh check
  ```

Done when the calendar piece reports `CONNECTED`. The agent MUST keep retrying
the probe after user action; it MUST NOT mark Calendar complete from user
assertion alone.

Dashboard updates:

Before probing:

```bash
ref/installer/client.sh installer_step calendar active "Checking Google Calendar" || true
```

If the probe reports `NOT_CONNECTED`, show exactly one browser action:

```bash
ref/installer/client.sh installer_step calendar waiting "Connect Google Calendar" browser "https://claude.ai/customize/connectors" || true
```

When connected:

```bash
ref/installer/client.sh installer_step calendar ok "Google Calendar connected" || true
ref/installer/client.sh installer_step activate active "Preparing text activation" || true
```

**Step 3 - Solo Plow activation.**

Who runs what:

- The agent starts real solo activation:

  ```bash
  DOMO_HOME=$HOME/.domo ref/domo-activate-piece.sh activate
  ```

- The activation piece prints an activation code and target number.
- The agent relays them to the user in chat in this form:

  ```text
  Text CODE to NUMBER from the phone Domo should use.
  ```

- The user sends exactly that text message.
- The activation piece continues polling Plow until redeem returns verified and
  writes:

  ```text
  $DOMO_HOME/.claude/plow-chat/state.json
  ```

Done when the activation piece reports `VERIFIED` and the state file is present,
chmod 600, and strictly shaped as `{base_url, token, chat_uid}`. The agent MUST
never print the token.

Dashboard updates:

While requesting activation:

```bash
ref/installer/client.sh installer_step activate active "Preparing text activation" || true
```

After the agent parses the activation `CODE` and `NUMBER` from the activation
piece output, it relays them to the user in chat and pushes the same public
copy-paste data to the dashboard:

```bash
ref/installer/client.sh installer_step activate waiting "Text the activation code" || true
ref/installer/client.sh installer_verify "You" pending "CODE" "NUMBER" self || true
```

The dashboard MUST NOT receive activation secrets or the Plow Bearer token. It
MAY receive only the public one-time activation code and target number that the
user must text.

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

The ready piece authors the default solo Domo config, registers the Plow chat
channel, starts the background Claude daemon, and sends the deterministic first
ready text through the real Plow `reply` path.

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

Solo activation is owned by:

```bash
DOMO_HOME=$HOME/.domo ref/domo-activate-piece.sh activate
```

It performs:

1. `POST /v1/auth/activate` with `{"name":"Domo","provision_chat":true}`.
2. User texts the displayed code to the displayed number.
3. Poll `POST /v1/auth/activate/redeem` until `status=verified`.
4. Write chmod-600 `{base_url, token, chat_uid}` state.

Activation secrets MUST pass through stdin or chmod-600 files, never command
arguments. Bearer tokens MUST be written chmod 600, never logged, never printed,
and never committed.

### Domo runs

Runtime startup is owned by:

```bash
DOMO_HOME=$HOME/.domo ref/domo-ready-piece.sh ready
```

The ready piece writes a lean default Domo config for a solo household, starts
the Claude Code daemon with the Plow chat channel loaded, and sends the first
ready text through the channel `reply` tool. `ref/domo-ready-piece.sh status`
prints non-secret readiness state. `ref/domo-ready-piece.sh stop` stops the
daemon and sweeps the channel child.

### Domo replies / reads the calendar / reports activity

User-visible replies MUST go through the Plow channel `reply` tool; transcript
output alone does not reach the chat. Calendar access MUST go through the
`mcp__claude_ai_Google_Calendar__*` connector tools. Logs and status output MUST
not contain the Plow Bearer token, activation secrets, or any metered API key.

## Verify

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

1. Login piece status confirms subscription auth:

   ```bash
   DOMO_HOME=$HOME/.domo ref/domo-login-piece.sh status
   ```

2. Calendar piece confirms the connector:

   ```bash
   DOMO_HOME=$HOME/.domo ref/domo-calendar-piece.sh check
   ```

3. Activation piece validates Plow activation mechanics against the stub:

   ```bash
   ref/domo-activate-piece.sh selftest
   ```

4. Ready piece validates config, channel connect, and first ready text against
   the stub:

   ```bash
   ref/domo-ready-piece.sh selftest
   ```

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

## Open

- **Group chat install** - group mode is a follow-on after the solo flow is
  stable.
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
- **No group install in this slice** - this SEED action installs solo only.
- **No non-macOS reference target** - non-macOS hosts are unsupported.
