# plow-chat

A Claude Code **channel** that bridges a real Plow Chat (SMS / texting)
conversation to a Claude Code session. Modeled on the `fakechat` channel
contract — same MCP/channel wiring — but the transport is the Plow Chat
WebSocket + REST API instead of a localhost web UI.

There is **no listening server** here: the channel is a WSS *client* plus a REST
sender. Nothing binds a port, so it never conflicts with `FAKECHAT_PORT`.

## How it loads

Loaded as a local plugin dir by the `domo` CLI (not a marketplace install):

```sh
claude --channels plugin:plow-chat --plugin-dir /Users/plucas/cncorp/seed-domo/channels/plow-chat
```

`.mcp.json` launches the server with `bun` exactly like fakechat. The
`start` script runs `bun install --no-summary && bun server.ts`.

## Secrets — never committed

The server reads `{ base_url, token, chat_uid }` from a **chmod-600** JSON state
file. It does **not** hardcode the path: it reads `process.env.PLOW_CHAT_STATE`
(an absolute path), mirroring how fakechat receives `FAKECHAT_PORT`. The `domo`
CLI exports `PLOW_CHAT_STATE` before launching `claude`.

State file shape (written by `./domo activate`):

```json
{
  "base_url": "https://api.plow.co",
  "token": "<USER-WIDE Bearer token — never logged or committed>",
  "chat_uid": "cht_..."
}
```

If `PLOW_CHAT_STATE` is unset, the file is missing/unparseable, or
`token`/`chat_uid` are empty, the server still starts the MCP stdio transport
(so `claude --channels` loads cleanly) but stays **unconnected**: `ListTools`
works, and `reply` returns an error telling you to run `./domo activate`. It
never crashes the transport. State is re-read lazily on each send and each
(re)connect, so a state file written *after* launch is picked up without a
restart (best-effort — if Claude caches the failed MCP server, restart with
`./domo stop && ./domo start`).

The token is **never** printed to stdout/stderr; on auth/send errors only the
HTTP status code is logged.

## Inbound / outbound

**Inbound** (Plow → Claude):

1. Mint a short-lived ticket: `POST /v1/ws/ticket {chat_id: <chat_uid>}` (Bearer).
2. Connect `wss://api.plow.co/v1/ws?ticket=<ticket>`; `connected` confirms.
3. On a `message_received` frame with `direction == 'inbound'`, fire the channel
   notification (`notifications/claude/channel`) with `content = message.body`
   and `meta = { chat_id, message_id: message.uid, user: sender.display_name, ts }`.
4. `direction == 'outbound'` frames are echoes of our own sends and are **ignored**.
5. On disconnect: re-mint a fresh ticket and **backfill** via
   `GET /v1/chats/{chat_uid}/messages`, de-duped by `message.uid`.

**Outbound** (Claude → Plow) — the `reply` tool:

- `POST /v1/chats/{chat_uid}/messages {body: "..."}` (Bearer).
- A `409 chat_not_ready` is surfaced as a clear tool error (chat not active yet);
  it is **not** retried until the chat is active.

## Tools

| Tool | Purpose |
| --- | --- |
| `reply` | Send a text message to the Plow Chat conversation. Takes `text`. Returns an error (not a crash) if state is missing or the chat is not yet active. |

No `edit_message`: the Plow send API (`POST /v1/chats/{uid}/messages`) has no
documented in-place edit, so the tool is omitted per the contract.

## Frames handled

`connected`, `chat_active`, `chat_activation_failed` (terminal — re-run
`./domo activate`), `participant_verified`, `message_received`,
`message_status_updated`.

## Runtime-unverified

The live Plow API is not exercised in this build (no token exists yet). The
inbound loop, echo filtering, reconnect/backfill, and 409 handling are
statically reviewed but their live behavior is runtime-unverified.
