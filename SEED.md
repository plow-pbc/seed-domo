# Purpose

> See [README#Purpose](README.md#purpose).

## Normative Language

The key words MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD NOT,
RECOMMENDED, MAY, and OPTIONAL in this document are to be interpreted as
described in RFC 2119. Sub-folder `SEED.md` files in this tree inherit this
declaration and MUST NOT re-declare it.

## Dependencies

`seed-domo` stands up one live, text-reachable Domo on the user's Mac. It does
not silently install system-wide software. The install action surfaces missing
dependencies early and stops on the first missing hard dependency.

**API**

- **Claude subscription auth** - Domo MUST run on an Anthropic Claude
  subscription through interactive `domo login` / Claude `/login` in the isolated
  config dir. `ANTHROPIC_API_KEY` MUST be unset so Domo never falls back to
  metered API billing.
- **claude.ai Google Calendar connector** - the Google Calendar connector MUST be
  enabled on the same Anthropic account used for `domo login`. The installer
  verifies this inside the logged-in Domo session by probing the
  `mcp__claude_ai_Google_Calendar__*` tools.
- **Plow Chat API, via
  [seed-plow-chat](https://github.com/plow-pbc/seed-plow-chat)** - Plow owns the
  line, activation, chat, WSS inbound, REST reply, and restart-safe backfill
  contract. The installing agent MUST install this external SEED leaves-first.
  Clone URLs MUST contain no userinfo, query string, or fragment.

**Software**

- **macOS** - the reference daemon uses macOS `/usr/bin/script` for a controlling
  PTY. Non-macOS hosts are unsupported.
- **Claude Code CLI >= 2.1.80** - the `claude` CLI MUST be on `PATH`.
- **`bun`** - runs the channel server, dashboard server, and small JSON helpers.
- **`jq`** - renders installer state and the readable transcript feed.
- **`expect`** - answers the custom-channel confirmation so the daemon can start
  in the background.

## Objects

- **The install driver** - `ref/installer/domo-install.sh`. This is the live
  install entry point for the `Domo is installed` action. A fresh install MUST run
  this driver, not bypass it with the older manual sequence.
- **The install state** - `$DOMO_HOME/install-state.json`, written atomically with
  chmod 600. It is the authoritative state machine for install progress. It may
  temporarily contain activation secrets, Bearer tokens, one-time codes, and
  member verification state, so it MUST be gitignored, never printed, and never
  committed.
- **The install dashboard** - `ref/installer`, a local 127.0.0.1 dashboard backed
  by an ephemeral tokenized HTTP/SSE state contract. It mirrors the install state
  and shows exact user actions; it does not drive the state machine and MUST NOT
  store secrets.
- **The Domo shell** - `ref/domo`, the reference lifecycle CLI. `setup` creates
  isolated dirs, a workspace, and one pinned session UUID. `activate` performs
  the Plow activation paths. `start` launches the same pinned session as a
  daemon. `status`, `doctor`, `logs`, and `stop` operate it.
- **The Domo session** - one persistent `claude --channels` process using
  subscription auth, `--permission-mode auto`, and the pinned session UUID. It
  MUST NOT use `bypassPermissions` by default.
- **The Plow Chat channel** - `ref/channels/plow-chat`, an MCP stdio server with
  the `claude/channel` capability. It reads `{base_url, token, chat_uid}` from
  the chmod-600 state file named by `PLOW_CHAT_STATE`; it MUST NOT hardcode that
  path and MUST NOT log the token.
- **The chat** - either a solo Plow chat or a group Plow chat. Solo activation
  redeems one phone code and provisions a 1:1 chat. Group activation redeems the
  owner token, creates a chat with member participants, persists the one-time
  member codes immediately, and waits until every member participant is active.
- **The workspace** - `$DOMO_HOME/workspace`, including the authored `CLAUDE.md`
  that records household shape and member names for the running session.
- **The calendar tools** - the `mcp__claude_ai_Google_Calendar__*` tools exposed
  by the claude.ai account connector.

## Actions

### Domo is installed

This action is the install. It MUST invoke:

```bash
ref/installer/domo-install.sh
```

The driver runs the phased, front-loaded install flow below and exits only after
Domo is ready or a specific gate is still waiting on the user. A conformance pass
that only clones the repo and runs structural checks is incomplete; a fresh SEED
install MUST continue into this driver so Phase 0 runs.

**Phase 0 - Bootstrap.** With no user interaction, the driver:

1. Checks hard tooling: `bun`, `jq`, `expect`, and `claude --version >= 2.1.80`.
2. Runs `ref/domo setup` to create the isolated config, workspace, run dir, Plow
   state dir, and pinned session UUID.
3. Launches the dashboard and opens the browser when available. If no browser is
   available, it renders the same state in the terminal.

`domo setup` MUST NOT print manual next-step prose. The dashboard and terminal
state are the user-facing surfaces.

**Phase 1 - Front-load inputs.** Immediately after the dashboard is reachable,
the driver asks exactly one terminal question:

```text
Solo or group? If group, who's in the household? (names - include yourself)
```

The dashboard shows a banner until this question is answered:

```text
One quick question is waiting in your terminal - answer it to continue.
```

At the same time, the dashboard shows the human-only actions that do not depend
on the answer:

- Run `domo login` in a new terminal. The installer does not mark this complete
  from a button or file; it confirms it later by starting/probing the Domo
  session.
- Enable Google Calendar at `https://claude.ai/customize/connectors` on the same
  account. The installer confirms it later by probing the calendar tools inside
  the logged-in Domo session.

After the answer, the driver reveals the Plow texting action:

- Solo: request activation with `provision_chat: true`, display the activation
  code and target number, poll redeem, then write the channel state.
- Group: activate the owner, list the line, create the group chat, persist the
  returned participant map and one-time codes immediately, show every member's
  code and target number, reconnect from persisted state on restart, and wait for
  `chat_active`.

The user can complete login, Calendar, and texting in any order. The installer
does every API call and every verification it can do itself.

**Phase 2 - Preflight and build while away.** The authoritative trigger is
`$DOMO_HOME/install-state.json`, not dashboard state. The driver proceeds only
when:

- `interview.status = collected`
- `activation = complete`
- login and Calendar are confirmed by preflight

Preflight starts the Domo session and waits for a fresh current-run channel
marker (`Listening for channel` / `channel messages from`). A stale transcript
file is not sufficient. If the login wall is still present, the driver leaves
`login=pending`, tells the user to run `domo login`, and retries on its cadence.
Once login is confirmed, the driver probes the Google Calendar connector inside
that same session. Only then does it author the runtime `CLAUDE.md`, wire the
activated Plow chat, start the daemon, and confirm readiness.

**Phase 3 - Ready.** The dashboard reaches done only when Domo is live:

```text
Domo is live - text <number> to talk to it.
```

### Domo is activated

Activation is performed by `ref/domo activate` under the install driver.

- **Solo** - `POST /v1/auth/activate {"name":"Domo","provision_chat":true}`;
  the user texts the displayed code; redeem returns the Bearer token and chat.
- **Group** - owner activation returns a token; the driver creates a chat with
  one agent line and all named members; each member texts their one-time code;
  WSS frames update participant status until all members are active.

Activation secrets MUST pass through stdin or files, never command arguments.
Bearer tokens MUST be written chmod 600, never logged, never printed, and never
committed.

### Domo runs

`ref/domo start` launches the pinned Claude session as a background daemon with
the Plow channel loaded as `server:plow-chat`. `ref/domo stop` MUST reap the
wrapper and the scoped Claude process without touching unrelated Domo instances.
`ref/domo status` and `ref/domo doctor` MUST reject any `DOMO_CHANNEL` value other
than `plow-chat`.

### Domo replies / reads the calendar / reports activity

User-visible replies MUST go through the channel `reply` tool; transcript output
alone does not reach the chat. Calendar access MUST go through the
`mcp__claude_ai_Google_Calendar__*` connector tools. Logs and status output MUST
not contain the Plow Bearer token, activation secrets, one-time codes after they
are no longer needed, or any metered API key.

## Verify

Verification is split by when a check can pass.

**Install-time** checks hold on a fresh clone once dependencies are present:

1. Are `bun`, `jq`, and `expect` on `PATH`, and is `claude --version` at least
   2.1.80?
2. Is `ANTHROPIC_API_KEY` unset?
3. Does `SEED.md` name `ref/installer/domo-install.sh` as the `Domo is installed`
   action entry point?
4. Do the structural checks pass?
   - `README.md` contains a `## Purpose` H2 outside fenced code blocks.
   - Root `SEED.md` has exactly one `# Purpose`, follows the canonical H2
     grammar, and includes `## Normative Language`.
   - Every `SEED.md` links its `# Purpose` body to the closest
     sibling-or-ancestor `README.md#purpose`.

**Runtime** checks hold only after `ref/installer/domo-install.sh` completes:

5. Is the isolated Domo instance signed in to a Claude subscription, with
   `ANTHROPIC_API_KEY` unset?
6. Is the Google Calendar connector confirmed from inside the running Domo
   session?
7. Is the Plow activation complete for the chosen solo/group shape, with a
   chmod-600 channel state file and no printed token?
8. Is the daemon running the pinned session with `plow-chat`, and does
   `ref/domo status` report the channel state without secrets?

The deterministic structural subset is implemented by:

```bash
bash ref/verify.sh
```

## Feedback

(none)

## Open

- **Morning briefing trigger** - a cron-injected morning message so Domo can
  proactively brief the household. Deferred.
- **Reboot survival** - a launchd job so the daemon survives a host reboot.
  Deferred.
- **Domo-specific authorization policy** - a future policy layer can narrow what
  verified chat members may ask Domo to do. The current core install treats all
  verified chat members equally.

## Non-Goals

- **No headless `claude -p` runtime** - Domo is channels-only; it is not driven by
  one-shot prompting.
- **No API key billing** - `ANTHROPIC_API_KEY` stays unset; Domo is
  subscription-billed and MUST NOT fall back to a metered key.
- **No shipped solo/group runtime toggle** - the chosen chat shape is collected
  during install and written into the authored workspace.
- **No non-macOS reference target** - non-macOS hosts are unsupported.
