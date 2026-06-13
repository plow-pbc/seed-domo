# Domo

A de-Plowed, agent-first household assistant that lives on your Mac, runs on your
Claude subscription, reads your texts, reasons, acts, and texts back.

## Purpose

**Domo** is a personal household assistant that runs as **one persistent
Claude session with the Plow chat channel loaded**
(`--dangerously-load-development-channels server:plow-chat`) on a Mac, billed
against your **Claude subscription** rather than a metered API key. A real
Plow Chat conversation is wired to that session, so you talk to Domo by text.
Domo receives a message, uses Claude Code and account-level tools such as
Google Calendar, then replies back into the same texting thread.

Domo is delivered as a **SEED**: a prose specification that an installing
agent reads to *generate* a live Domo, solo or group. The install clusters
everything that needs you into **one decision moment** on a generated
installer page; the agent does everything else.

`ref/` ships exactly one file, `verify.sh`, the structural conformance
checker — the conversion to composed sub-SEEDs is complete. All runtime is
generated at install time into the baked Domo home by the slices under
`seeds/`.

## Install

The standard entry point is `/seed-install`, which audits the cloned tree before
running the install action:

```bash
/seed-install https://github.com/plow-pbc/seed-domo
```

Already have the SEED skills? Point an agent at this repo:

```bash
git clone https://github.com/plow-pbc/seed-domo && cd seed-domo
```

Then run `/seed-install .`, or open the checkout and ask the agent to install
this SEED.

The headline of the install is the **generated installer page** and the **one
decision moment**: moments after kickoff the agent generates and opens a local
installer page — even before anything else completes — works alone while the
page narrates progress, then gathers everything that needs you into a single
sitting (household setup, login and Calendar connector watches, calendar
selection, texting the activation message), and runs unattended to
completion. The page is generated at install time and served from a
loopback-only local endpoint; if no browser is available the install degrades
to a static page or plain chat and never blocks.

The agent resolves the persistent Domo home once, as an install constant
(default `~/.domo`, outside the checkout), and bakes that absolute path into
every generated file. No environment variable is read at runtime.

The installing agent follows `SEED.md` and walks the seven entries
leaves-first — two behavioral contract seeds are read and recorded, five
generated slices install their runtime into the baked home:

1. **Login.** `seeds/claude-instance/SEED.md` — isolated Claude subscription
   auth helpers under `~/.domo/runtime/claude-instance`, verifying
   `~/.domo/.claude`.
2. **Calendar.** `seeds/calendar-connector/SEED.md` — connector probe helpers
   under `~/.domo/runtime/calendar-connector`, verifying the claude.ai Google
   Calendar connector on the same account.
3. **Display contract.** `seeds/household-display/SEED.md` — a purely
   behavioral contract seed (installs nothing): the single declaring site
   for the household display surface, its card feed, and the compose
   grammars the producers cite.
4. **Rhythms contract.** `seeds/daily-rhythms/SEED.md` — a purely behavioral
   contract seed (installs nothing): the household rhythm cadence table
   (morning recap, hourly weather) and behavior pipelines the host bakes.
5. **Channel server.** `seeds/plow-channel-server/SEED.md` — the generated MCP
   channel server under `~/.domo/runtime/plow-channel-server` that bridges the
   daemon to the Plow chat: the `reply` tool out, inbound texts in, and the
   rhythm scheduler module inside it firing the baked cadence table.
6. **Activation.** `seeds/plow-activation/SEED.md` — Plow text activation
   helpers under `~/.domo/runtime/plow-activation`, solo or group mode,
   writing chmod-600 channel state and transcribing the decision-moment
   answers into install state.
7. **Runtime.** `seeds/domo-runtime/SEED.md` — `~/.domo/bin/domo` and runtime
   helpers under `~/.domo/runtime/domo-runtime`; authors the workspace
   (including the rhythm instructions), starts the pinned-session daemon and
   the loopback household dashboard under one tmux session, gates readiness
   on host channel registration, and sends the first ready text.

The only things you do are the setup form on the installer page, the
interactive subscription login if it is needed, the browser connector toggle
if it is needed, and texting the activation message from the relevant phone.
Tokens and one-time codes stay in chmod-600 gitignored state files and are
never printed.

## Usage

After install, Domo runs as one pinned, persistent session. The generated CLI is:

```bash
$HOME/.domo/bin/domo ready   # launch the daemon and send the first ready text
$HOME/.domo/bin/domo start   # launch the daemon + household dashboard
$HOME/.domo/bin/domo status  # config + daemon/dashboard liveness + channel state, no secrets
$HOME/.domo/bin/domo logs    # readable transcript feed
$HOME/.domo/bin/domo doctor  # read-only preflight
$HOME/.domo/bin/domo stop    # stop daemon, dashboard, and scoped channel children
$HOME/.domo/bin/domo reset   # delegated cleanup/logout plus guarded local removal
```

`$HOME/.domo/bin/domo logs` renders inbound texts, replies, and tool activity
from the pinned-session transcript.

Domo also serves a loopback-only **household dashboard** — four card slots
(alert, message, weather, digest) plus an agenda section — fed by the
rhythms: an hourly weather card and the morning recap's digest card.
`domo status` prints its local URL; it lives and dies with `domo
start`/`stop`, and a dashboard failure never blocks chat.

## Security Posture

- Domo uses Claude subscription auth. `ANTHROPIC_API_KEY` must stay unset, and
  generated Claude launch paths unset it before invoking Claude.
- The Plow Bearer token is user-wide. It is stored chmod 600 under the isolated
  `.claude/plow-chat` state dir, gitignored, never logged, never printed, and
  never committed.
- Activation secrets are passed through stdin or files, not command arguments.
- The daemon uses `--permission-mode auto`, not `bypassPermissions` by default.
- The Google Calendar connector is account-scoped in claude.ai. Keep that
  account's connected surface minimal.

## License

[MIT](LICENSE) © 2026 plow-pbc. Use, modify, and redistribute freely with
attribution.
