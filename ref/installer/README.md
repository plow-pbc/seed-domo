# Install dashboard — a generic, agent-driven install UI

A small local web page that shows a user, at every moment, **exactly what to do**
and **what's being waited on**, with steps that flip to ✓ on their own. It is
**agent- and SEED-agnostic**: a driver (any agent that can spawn a process and make
HTTP calls — Claude, Codex, Gemini) feeds it a JSON **state object** over a plain
HTTP/SSE contract, and it renders that. It knows nothing about Domo, Claude, Plow,
or connectors — all of that lives in the driver. This is the portability boundary;
keep it small.

> Domo is this installer's first consumer. Domo's driver is its `SEED.md`
> "Domo is installed" Action + `ref/domo`. A different SEED reuses the same server +
> SPA unchanged and supplies its own steps.

## Pieces

- `server.ts` — bun server: serves the SPA and relays state. Holds the current state
  object in memory. **No logic, no secrets.**
- `app/` — the SPA (`index.html`, `app.js`, `style.css`). Renders whatever the state
  object holds. Hardcodes nothing about Domo.
- `start.sh` — **one command** to bring the dashboard up: launches the server
  detached, waits for it, opens the browser, and prints the drive recipe.
- `client.sh` — shell helper. Low-level (`installer_push '<state>'`) **and** a
  one-liner **verb layer** that keeps cumulative state in a file so a driver updates
  one thing at a time (see *Driving it*).
- `plow-stub.ts` — runnable Plow API/WSS fixture for install E2E. Covers solo
  activation, group chat creation, member verification frames, and ordered call
  recording.
- `e2e-install.sh` — committed solo+group E2E runner. It enters through
  `domo-install.sh`, points it at `plow-stub.ts`, and asserts ready state, call
  order, daemon liveness, and chmod-600 channel state shape.

## Running

```bash
ref/installer/start.sh                      # launch + open browser (the easy path)
# or, by hand:
bun run ref/installer/server.ts            # prints + writes server-info JSON, then serves
```

## Plow Stub Fixture

The Plow stub is the deterministic replacement for live SMS/WSS in local and CI
install tests.

Run it:

```bash
PLOW_STUB_STATE_DIR=/tmp/domo-plow-stub bun run ref/installer/plow-stub.ts
```

It writes:

```bash
/tmp/domo-plow-stub/server-info
```

with:

```json
{ "base_url": "http://127.0.0.1:PORT", "port": PORT }
```

Point Domo activation at it:

```bash
base_url="$(jq -r .base_url /tmp/domo-plow-stub/server-info)"
PLOW_CHAT_BASE_URL="$base_url" ref/installer/domo-install.sh
```

Covered Plow endpoints:

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/v1/auth/activate` | Create owner/solo activation and return `display_code`, `send_to`, `activation_secret`. |
| `POST` | `/v1/auth/activate/redeem` | Return `pending` until the exact activation code is posted to `/_stub/text`, then return token/chat. |
| `GET` | `/v1/lines` | Return the stub agent line for group chat creation. |
| `POST` | `/v1/chats` | Create a group chat with pending member participants and one-time `VERIFY-*` codes. |
| `POST` | `/v1/chats/:chat/invitations/:participant/resend` | Re-issue a pending member verification code. |
| `POST` | `/v1/ws/ticket` | Mint a WSS ticket for a known chat. |
| `GET` | `/v1/ws?ticket=...` | WSS stream: emits `connected`, then `participant_verified` and `chat_active` as codes arrive. |

Test helper endpoints:

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/_stub/text` | Simulate a phone texting an exact activation or `VERIFY-*` code. |
| `POST` | `/_stub/config` | Set `ws_close_on_open`, `redeem_error_status`, or `response_delay_ms`. |
| `GET` | `/_stub/calls` | Return counters and ordered Plow API call sequence. |

Run the committed E2E:

```bash
ref/installer/e2e-install.sh        # solo + group
ref/installer/e2e-install.sh solo
ref/installer/e2e-install.sh group
```

### Driving it (one-liners — no hand-built JSON)

```bash
ref/installer/client.sh installer_reset  "Setting up Domo"
ref/installer/client.sh installer_step   <id> <status> [label] [where] [command|link]
ref/installer/client.sh installer_verify <name> <status> [code] [number] [self]
ref/installer/client.sh installer_done   "Domo is live — text +1555… to talk to it"
```

`installer_step` upserts a step by `id` (preserving order); `status` ∈
`pending|waiting|active|ok|error`; `where` ∈ `terminal|browser|phone|other` and the
5th arg becomes the step's copy-paste `command` (terminal) or `link` (browser). Each
call mutates the cumulative state in `$INSTALLER_STATE_DIR/state.json` and re-pushes
the whole object, so calls work across separate shells. The interview itself can
stay in the agent's native question UI; the dashboard is the status surface.

The server binds **127.0.0.1** on an **ephemeral port**, mints a random URL
**token**, and writes connection info to
`${INSTALLER_STATE_DIR:-$TMPDIR/installer-ui}/server-info` as JSON
(`DOMO_INSTALLER_STATE_DIR` is also honored as a back-compat alias):

```json
{ "url": "http://127.0.0.1:PORT", "port": PORT, "token": "<rand>",
  "events_url": "http://127.0.0.1:PORT/s/<rand>/events",
  "state_url":  "http://127.0.0.1:PORT/s/<rand>/state" }
```

A driver opens `url` in the browser (`open <url>` on macOS) and uses the other URLs.

## Endpoints

| Method | Path | Auth | Purpose |
|---|---|---|---|
| `GET` | `/` | — | The SPA (the server injects the token so the page's JS can talk back). |
| `GET` | `/app.js`, `/style.css` | — | Static assets. |
| `GET` | `/s/<token>/events` | token in path | **SSE**. Emits `data: <state-json>\n\n` on connect and on every change. |
| `POST` | `/s/<token>/state` | token in path | Driver pushes the **full** state object (JSON). Replaces state, broadcasts over SSE. |
| `GET` | `/healthz` | — | `{"status":"ok"}`. |

The `<token>` path segment guards state/events so another local process can't read
or inject. The SPA learns the token from the injected page; the driver reads it
from `server-info`.

## The state object (the contract)

The driver `POST`s this **whole object** to `/state` on every change. All values are
display data the driver supplies; the SPA renders them. **No secrets ever** (see
below).

```jsonc
{
  "title":    "Setting up Domo",            // header
  "kicker":   "Setting up · step 3 of 7",   // small mono label above the title
  "subtitle": "This page checks each step off on its own…",
  "steps": [
    {
      "id":     "login",                    // stable id
      "label":  "Sign in to Claude",
      "status": "ok" | "pending" | "waiting" | "active" | "error",
      "detail": "optional one-line note (e.g. what was found)",
      "action": {                           // present on a waiting step
        "instruction": "Opens Domo's folder in Claude; type /login when it loads.",
        "where":   "terminal" | "browser" | "phone" | "other",
        "command": "~/domo/seed-domo/ref/domo login",   // exact copy-paste (terminal)
        "link":    "https://claude.ai/…"                 // labeled URL (browser)
      }
    }
  ],
  "verification": [                          // present on the verify step; else null
    { "name":"Patrick", "isSelf":true,  "status":"verified" },
    { "name":"Sarah",   "isSelf":false, "status":"pending",
      "code":"VERIFY-EF34GH", "number":"+15550000002", "canResend":true }
  ],
  "message": "optional banner text",
  "done": false                              // true on the final success state
}
```

Enums: `status` ∈ `pending|waiting|active|ok|error`; `where` ∈
`terminal|browser|phone|other`; verification `status` ∈ `pending|verified|error`.

### Rendering rules (SPA)

- A step is a row: status icon (✓ done, sage **spinner** for `active`/`waiting`,
  number/✗ otherwise) + label + `detail`.
- A `waiting` step with `action` expands into a card: a mono "↳ where" label, the
  `instruction`, and — for `where:"terminal"` — a **dark command box** containing
  `command` with a **Copy** button; for `where:"browser"`, a labeled link button.
- `verification` renders one row per member: avatar, name, (for non-self) the `code`
  in a chip with **Copy** + the `number` to text, and a live status (spinner →
  ✓ Verified), over a "N of M verified" progress bar.
- Style: **Plow Seeds** — chalk/oat bg, white cards, sage-green `#5e7a5e` accent,
  DM Sans + DM Mono, dark command boxes. Match `seeds.plow.co`.

## Security (hard rules)

- **No secrets in state.** The state object MUST NOT contain bearer tokens, API
  keys, passwords, or credentials. The server **rejects** (`400`) a `/state` body
  whose JSON contains any string matching a secret pattern (`Bearer `, `plow_…`,
  `sk-…`, `ghp_…`, keys named `*token*`/`*secret*`/`*password*`/`*key*` with a
  secret-looking value). Verification `code`s (`VERIFY-…`, one-time, meant to be
  shown) are allowed.
- Bind `127.0.0.1` only; ephemeral port; random path token; in-memory state only;
  no persistence of state to disk beyond `server-info`.
- The process is ephemeral — a driver kills it when the install reaches `done`.
