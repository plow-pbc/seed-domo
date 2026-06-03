# Domo

A de-Plowed, agent-first household assistant that lives on your Mac, runs on your
Claude subscription, reads your texts, reasons, acts, and texts back.

## Purpose

**Domo** is a personal household assistant that runs as **one persistent
`claude --channels` session** on a Mac, billed against your **Claude
subscription** (never a metered API key). It is *de-Plowed* and *agent-first*: a
single always-on Claude Code session is wired to a real texting conversation, so
you talk to it the way you'd text a person. A message comes in, Domo **reasons**
about it, **acts** — checks your Google Calendar, looks something up, runs a
local task — and **texts you back**. No app to open, no dashboard to babysit:
just a thread on your phone and an agent on the other end.

Domo is delivered as a **SEED**, not as a shrink-wrapped product. A SEED is a
descriptive knowledge base plus a working reference implementation that an
**agent** uses to stand up *your* Domo. You don't run an installer that imposes
one fixed shape. Instead you point an agent at [`SEED.md`](SEED.md) and it
**interviews you** — how do you want to use Domo? Just you, or a household group?
What should it be allowed to do? What persona, what trust posture? — and then it
**writes the Domo software that fits your answers**, consulting the reference for
the mechanics but free to build it however you want. Nothing is dictated. Solo
versus group is not a runtime switch; it is a question the install asks, and the
answer changes the software the agent writes.

The result is yours: a small, legible, single-session assistant you understand,
running on hardware and an account you control, with no third-party product
sitting between you and your agent.

> `ref/` in this repo is **implementation reference** — a working example of the
> moving parts (the texting channel, the backgrounded session daemon, calendar
> tools, the activation handshake). It is there to show *how* the pieces fit, not
> a product you must run as-is. The agent and you read it to understand the
> mechanics; your Domo can reuse, adapt, or replace any of it.

## Install

Installing Domo is a one-shot, agent-led conversation — not a `./install` you run
blindly. The standard entry point is the SEED convention's bootstrap, which
installs the `seed-create` / `seed-install` / `seed-verify` skills and then
launches an agent pre-seeded to install this SEED:

```bash
curl -fsSL https://raw.githubusercontent.com/plow-pbc/seed/main/install.sh \
  | bash -s -- https://github.com/plow-pbc/seed-domo
```

Already have the skills? Just point an agent (Claude Code) at the SEED directly —
clone it and run `/seed-install https://github.com/plow-pbc/seed-domo`, or open
the checkout and say *"install this SEED"*:

```bash
git clone https://github.com/plow-pbc/seed-domo && cd seed-domo
```

Either way, the agent drives the whole thing in real time. It does the work inline
and ends with a **live Domo** — not a list of commands and settings left for you.

> **"Installing Domo" means running it, not just checking out the repo.** A bare
> SEED conformance pass (e.g. `/seed-install`: clone, check tools, run the
> structural checks) is only the scaffolding — on its own it leaves Domo unbuilt
> and not running. The real install is the **onboarding**: the interview, writing
> your Domo, login, activation, and start. SEED.md wires the conformance pass to
> roll **straight into** the onboarding, so you end up running — not staring at a
> "now go do these steps" list. Done = Domo signed in and answering texts.

Working from the SEED, the agent will:

1. **Interview you up front** — solo or a household group, who the members are,
   what persona it should have, what it's allowed to do. All the questions in one
   pass, so the rest runs without interruptions.
2. **Walk every requirement with you** — the tooling (macOS, Claude Code with the
   `channels` research preview, `bun`, `jq`, `expect`), an interactive **`/login`**
   to your Claude **subscription** (no API key), and the claude.ai **Google
   Calendar connector** — which it then *verifies* by checking that the calendar
   tools actually show up — plus the **seed-plow-chat** channel that bridges a real
   texting conversation to the session.
3. **Write your custom Domo software** to match, consulting `ref/` for the proven
   mechanics but assembling exactly what you asked for.
4. **Set it up, activate, and start it — itself, inline.** The agent runs the
   bootstrap, runs the Plow activation (surfacing the code(s) for you to text in),
   and launches the background session, then verifies everything is live. Getting
   the Plow token is part of the install, not a command you run later.

A few steps only *you* can do (the agent pauses and asks, then resumes): the
interactive `/login`, enabling the Google Calendar connector in the browser, and
texting the verification code(s) from your phone. The SEED makes those explicit;
it never tries to do them for you.

To keep that crisp, the agent can drive the whole install through a **clean local
web page** ([`ref/installer/`](ref/installer/)) — a generic, agent-agnostic install
dashboard that shows each step, the exact copy-paste command for anything you must
run, and live ✓ status (including per-person phone verification). It falls back to
plain terminal Q&A when there's no browser.

## Usage

Once Domo is installed, the reference `ref/domo` CLI shows how the lifecycle is
operated. (Your authored Domo may expose its own commands; the surface below is
the reference example.) Domo runs as **one pinned, persistent session** — the
foreground `shell` (for one-time login/consent/debug) and the background daemon
share a single session UUID, so they're one continuous conversation.

```bash
ref/domo setup       # idempotent bootstrap: isolated dirs, workspace, pinned session UUID
ref/domo activate    # Plow handshake: print the code to text, poll redeem, write chmod-600 state
ref/domo doctor      # read-only preflight: tooling, auth, ANTHROPIC_API_KEY unset, channel state
ref/domo start       # launch the background daemon (the one pinned session)
ref/domo status      # resolved config + daemon liveness + channel state (no secrets)
ref/domo logs        # readable transcript feed of what Domo is reading, thinking, and sending
ref/domo stop        # stop the daemon (tree-kill) + sweep the stray channel child
```

**`ref/domo logs`** is the window into a running Domo: it renders the **readable
transcript feed** (inbound texts, Domo's replies, tool activity) rather than raw
PTY output. Add `--raw` for the underlying PTY/TUI capture, or `--no-follow` for
a one-shot read.

### One-time setup

`ref/domo setup` is idempotent. It points `CLAUDE_CONFIG_DIR` at an isolated
config dir under the repo root, creates the workspace and runtime dirs, mints and
persists the **pinned session UUID**, and verifies the selected channel is
loadable. It does **not** log you in or activate anything — those are the
interactive steps the SEED walks you through:

- **Connect Google Calendar (browser, once).** At
  [claude.ai/customize/connectors](https://claude.ai/customize/connectors),
  connect **Google Calendar** using the **same Anthropic account** you'll `/login`
  with. Connectors are account-scoped, so they surface in the session as
  `mcp__claude_ai_Google_Calendar__*` tools.
- **Log this instance in.** Run `ref/domo shell`, then `/login` with that same
  subscription account, and accept the channels research-preview consent once (it
  needs a real TTY, which `shell` provides). A fresh isolated config dir does not
  inherit your personal Claude Code login.
- **Activate the texting channel.** `ref/domo activate` runs the Plow handshake:
  it prints a code and a number; from the phone you want bound to the chat, text
  the code in. It then polls until verified and writes a **chmod-600** state file.
  Re-run with `--force` to re-activate.

### Auth

Auth is the interactive `/login` above. For a fully unattended run you can mint a
**subscription** token (`claude setup-token`) and let `ref/domo` pick it up from
the environment. It is a subscription token, **not** an API key — keep
`ANTHROPIC_API_KEY` unset; every launch unsets it and `ref/domo doctor` asserts
it.

### Permissions

The session runs `--permission-mode auto` — a classifier-gated guard, **not**
bypass mode. Read-only ops, the channel reply, and local workspace file ops are
auto-approved (so the read-calendar-then-reply loop never stalls); destructive and
external-write actions are blocked-but-overridable; exfiltration is always
blocked. Auto mode is a *generic* guard, not a Domo policy: it does not stop
calendar **writes**, and an always-on agent reading **untrusted inbound texts** is
a prompt-injection surface. Add a Domo-specific authorization layer before you let
Domo act on others' behalf.

### Security posture

- The Plow **Bearer token** is **user-wide**: stored **chmod-600** in the state
  file (parent dir chmod-700), gitignored, **never logged, printed, or
  committed**. `status`/`doctor` report only `present`/`missing`. The activation
  secret is passed via stdin, never on a command line.
- `ANTHROPIC_API_KEY` stays **unset** — Domo uses subscription auth only.
- One isolation caveat: the Google Calendar **connector is account-scoped**, so
  this instance inherits every connector on the account you `/login` with. Config,
  plugins, sessions, and channel state stay isolated; connectors don't. Keep the
  account's connected surface minimal.

## License

[MIT](LICENSE) © 2026 plow-pbc. Use, modify, and redistribute freely with
attribution.
