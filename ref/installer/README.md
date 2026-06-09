# Install dashboard — a generic, agent-driven install UI

A small local web page that shows a user, at every moment, exactly what to do
and what is being waited on, with steps that flip to complete on their own. It
is agent- and SEED-agnostic: a driver feeds it a JSON state object over a plain
HTTP/SSE contract, and it renders that. It knows nothing about Domo, Claude,
Plow, or connectors.

> Domo is this installer's first consumer. Domo's driver is its `SEED.md`
> "Domo is installed" Action plus the current monolith scripts in `ref/`.

## Pieces

- `server.ts` — bun server: serves the SPA and relays state. Holds the current
  state object in memory. No logic, no secrets.
- `app/` — the SPA (`index.html`, `app.js`, `style.css`). Renders whatever the
  state object holds. Hardcodes nothing about Domo.
- `start.sh` — one command to bring the dashboard up: launches the server
  detached, waits for it, opens the browser, and prints the drive recipe.
- `client.sh` — shell helper. Low-level (`installer_push '<state>'`) and a
  one-liner verb layer that keeps cumulative state in a file so a driver updates
  one thing at a time.

The old committed Plow stub and e2e runner are intentionally gone. Baseline and
slice rehearsals use real local services supplied outside this shipped tree.

## Running

```bash
ref/installer/start.sh
# or, by hand:
bun run ref/installer/server.ts
```

### Driving it

```bash
ref/installer/client.sh installer_reset  "Setting up Domo"
ref/installer/client.sh installer_step   <id> <status> [label] [where] [command|link]
ref/installer/client.sh installer_verify <name> <status> [code] [number] [self]
ref/installer/client.sh installer_done   "Domo is live - text +1555... to talk to it"
```

`installer_step` upserts a step by `id` while preserving order. `status` is one
of `pending`, `waiting`, `active`, `ok`, or `error`. `where` is one of
`terminal`, `browser`, `phone`, or `other`; the fifth argument becomes the
copy-paste `command` for terminal actions or `link` for browser actions. Each
call mutates `$INSTALLER_STATE_DIR/state.json` and re-pushes the whole object,
so calls work across separate shells.

The server binds `127.0.0.1` on an ephemeral port, mints a random URL token, and
writes connection info to `${INSTALLER_STATE_DIR:-$TMPDIR/installer-ui}/server-info`
as JSON. `DOMO_INSTALLER_STATE_DIR` is also honored as a back-compat alias:

```json
{
  "url": "http://127.0.0.1:PORT",
  "port": PORT,
  "token": "<rand>",
  "events_url": "http://127.0.0.1:PORT/s/<rand>/events",
  "state_url": "http://127.0.0.1:PORT/s/<rand>/state"
}
```

## Endpoints

| Method | Path | Auth | Purpose |
|---|---|---|---|
| `GET` | `/` | - | The SPA; the server injects the token so page JS can talk back. |
| `GET` | `/app.js`, `/style.css` | - | Static assets. |
| `GET` | `/s/<token>/events` | token in path | SSE stream of the current state. |
| `POST` | `/s/<token>/state` | token in path | Driver pushes the full state object. |
| `GET` | `/healthz` | - | `{"status":"ok"}`. |

## State Object

The driver posts this whole object to `/state` on every change. All values are
display data the driver supplies; the SPA renders them. No secrets ever.

```jsonc
{
  "title": "Setting up Domo",
  "kicker": "Setting up - step 3 of 7",
  "subtitle": "This page checks each step off on its own...",
  "steps": [
    {
      "id": "login",
      "label": "Sign in to Claude",
      "status": "ok",
      "detail": "optional one-line note",
      "action": {
        "instruction": "Run this command in a terminal.",
        "where": "terminal",
        "command": "DOMO_HOME=$HOME/.domo ref/domo-login-piece.sh login"
      }
    }
  ],
  "verification": [
    {
      "name": "Patrick",
      "isSelf": true,
      "status": "verified"
    }
  ],
  "message": "optional banner text",
  "done": false
}
```

## Security

- No secrets in state. The server rejects (`400`) state JSON containing bearer
  tokens, API keys, passwords, or credential-looking fields. Verification codes
  and activation messages intended for user display are allowed.
- Bind `127.0.0.1` only; ephemeral port; random path token; in-memory server
  state only.
- The process is ephemeral; a driver kills it when the install reaches `done`.
