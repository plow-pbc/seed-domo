# Purpose

> See [README#Purpose](../../README.md#purpose).

## Dependencies

This slice generates the Claude MCP channel server that bridges the persistent
Domo daemon to the already-activated Plow Chat conversation.

Hard dependencies:

- **Plow Chat contract SEED** - the installing agent MUST clone
  `https://github.com/plow-pbc/seed-plow-chat` from `origin/main` before
  generation, verify `git rev-parse HEAD` is
  `b4656d9d2fda82c9525dadc186834003b996055c`, and read that SEED's
  `## Objects` and `## Actions` as the only Plow HTTP and WebSocket API
  surface. This Domo SEED MUST NOT restate Plow endpoints, payload schemas,
  response schemas, or frame schemas.
- **Plow activation slice** - `<HOME>/.claude/plow-chat/state.json` MUST be
  written by `seeds/plow-activation/SEED.md` before live Verification can prove
  outbound sends, WebSocket connection, backfill, and DTU-driven inbound
  delivery.
- **`bun`** - the generated MCP registration launches the channel server with
  Bun.

The installing agent MUST resolve the Domo home once before generation,
defaulting to `$HOME/.domo` for user installs. Generated runtime files MUST
embed that literal path and MUST NOT read `DOMO_HOME`, `PLOW_CHAT_STATE`, or
`PLOW_CHAT_CONNECTED_MARKER` at runtime.

## Objects

- **Baked Domo home** - the absolute install home selected before generation.
  This slice writes only under that home.
- **Plow channel server runtime dir** -
  `<HOME>/runtime/plow-channel-server`, the externally consumed channel
  directory passed to `domo-runtime` registration. It MUST contain the Claude
  MCP registration metadata and whatever generated entrypoint or support files
  that metadata invokes. Internal filenames, file splits, package metadata, and
  dependency-management files are the generating agent's choice unless another
  slice consumes them across a seam.
- **Plow channel MCP registration** -
  `<HOME>/runtime/plow-channel-server/.mcp.json`, the externally consumed Claude
  MCP registration metadata for the `plow-chat` server. It MUST invoke an
  entrypoint under `<HOME>/runtime/plow-channel-server`.
- **Plow local state dir** - `<HOME>/.claude/plow-chat`, chmod 700.
- **Plow channel state** - `<HOME>/.claude/plow-chat/state.json`, chmod 600,
  exactly `{base_url, token, chat_uid}` as written by `plow-activation`.
  `chat_uid` is authoritative for channel notification `chat_id`. The token
  MUST never be printed, logged, passed in argv, or committed.
- **Connected marker** - `<HOME>/.claude/plow-chat/connected`, a non-secret
  marker read by operator status and diagnostics after the channel server proves
  WebSocket liveness.
- **MCP channel surface** - the generated server advertises
  `experimental["claude/channel"]`, exposes exactly the `reply` tool, and emits
  channel notifications to Claude.

## Actions

### Plow channel server is generated

The installing agent MUST generate this slice into the baked Domo home. It MUST
NOT copy `ref/channels/plow-chat`, vendor a prewritten server, or depend on any
committed channel implementation as the installed runtime.

1. Clone `https://github.com/plow-pbc/seed-plow-chat` from `origin/main` into a
   scratch directory and read its `## Objects` and `## Actions` before writing
   any server code. Treat that SEED as the only source for Plow HTTP calls,
   WebSocket ticketing, backfill behavior, frame names, and message fields.
2. Resolve the baked home before generation. Create:

   ```text
   <HOME>/runtime/plow-channel-server
   <HOME>/.claude/plow-chat
   ```

3. Generate a launchable MCP stdio channel server under
   `<HOME>/runtime/plow-channel-server` and generate the `.mcp.json`
   registration metadata that invokes it. The generated server MUST contain the
   baked absolute `<HOME>` literal and MUST derive its state path, high-water
   mark path, and connected marker path from that literal. It MUST NOT read
   `DOMO_HOME`, `PLOW_CHAT_STATE`, or `PLOW_CHAT_CONNECTED_MARKER`. Internal
   implementation shape is otherwise deliberately unconstrained: the generating
   agent MAY choose any filenames, module split, package metadata, or Bun launch
   wrapper that satisfies the externally consumed registration and behavioral
   gates.
4. The generated `.mcp.json` MUST register one MCP server named `plow-chat`
   whose command starts the generated entrypoint under
   `<HOME>/runtime/plow-channel-server`.
5. The generated MCP server MUST advertise:

   ```json
   {"tools":{},"experimental":{"claude/channel":{}}}
   ```

6. The generated server instructions MUST include this exact discipline:

   ```text
   Anything you want them to see MUST go through the reply tool
   ```

   The instructions MUST also state that inbound messages arrive as
   `<channel source="plow-chat" chat_id="..." message_id="...">` events and that
   `provider_key` in meta identifies the texting sender.
7. The generated `reply` tool MUST be named exactly `reply`, MUST take an
   `inputSchema` object with a required string property `text`, and MUST
   describe that it sends a text message to the Plow Chat conversation. Empty
   text MUST return a tool error. Missing or malformed state MUST return a tool
   error without crashing the MCP stdio transport. A `chat_not_ready` conflict
   MUST return a clear tool error and MUST NOT crash or retry in a tight loop.
8. Inbound Plow messages MUST be delivered through MCP notifications with:

   ```json
   {
     "method": "notifications/claude/channel",
     "params": {
       "content": "<message body>",
       "meta": {
         "chat_id": "<state.chat_uid>",
         "message_id": "<message uid>",
         "user": "<sanitized display name or You>",
         "ts": "<message timestamp or receive timestamp>",
         "provider_key": "<sender provider key when present>"
       }
     }
   }
   ```

   `chat_id` MUST come from `state.chat_uid`. Sender display names MUST strip
   `"`, `<`, `>`, carriage returns, and newlines, then default to `You` when the
   result is empty.
9. The generated server MUST read state lazily and never throw on absent,
   unreadable, or malformed state. While state is unavailable, it MUST keep the
   MCP transport alive, keep `reply` erroring, and re-poll every 3 seconds until
   valid state appears.
10. The generated WebSocket supervisor MUST treat a `connected` frame as channel
    liveness and write the connected marker. This is deliberately the opposite
    of the activation slice, which ignores `connected` for activation progress;
    the generated code and review checklist MUST NOT unify those two rules.
11. The generated inbound path MUST ignore outbound echoes, de-duplicate by
    message UID, persist `last_seen.json` chmod 600, and cap the high-water mark
    at 2000 UIDs.
12. First backfill after a fresh server start MUST seed the high-water mark
    without delivering historical messages. On daemon restart, historical
    messages already in the chat MUST NOT be replayed to Claude; fresh DTU
    inbound after restart MUST still be delivered.
13. The generated supervisor MUST use these pinned timing values:

    ```text
    CONNECT_TIMEOUT_MS=30000
    IDLE_TIMEOUT_MS=90000
    INITIAL_BACKOFF_MS=1000
    MAX_BACKOFF_MS=30000
    BACKOFF_RESET_AFTER_MS=10000
    STATE_REPOLL_MS=3000
    LAST_SEEN_CAP=2000
    ```

14. Generated logging MUST go to stderr, MUST include status codes only for Plow
    failures, and MUST never include the Bearer token, Authorization header, or
    request/response bodies that could echo secrets.

If this slice's `## Verification` fails because a generated server is wrong,
the installing agent MUST regenerate this slice exactly once and rerun
Verification. If the rerun still fails, stop the install, write terminal
`failure` with the reason to the repo-root `install-report.json`, and do not
attempt a third generation. There is no vendored fallback unless a recorded
head-chef escalation decision explicitly authorizes it.

## Verification

Verification runs against the just-generated real instance. It is live operator
evidence only, plus the thin self-checks needed to decide whether the
regenerate-once policy has passed or failed.

1. The generated channel interface MUST exist where `domo-runtime` consumes it,
   and the secret-bearing channel state MUST be private:

   ```bash
   test -d "<HOME>/runtime/plow-channel-server"
   test -f "<HOME>/runtime/plow-channel-server/.mcp.json"
   test "$(stat -f '%Lp' "<HOME>/.claude/plow-chat/state.json" 2>/dev/null || stat -c '%a' "<HOME>/.claude/plow-chat/state.json")" = 600
   ```

2. Start the real generated operator path that consumes this channel server and
   prove the daemon stays up. Evidence MUST include `status --assert` returning
   0 immediately after start and again after a hold of at least 120 seconds.

3. Send through the real `reply` path and confirm the message lands in the Plow
   chat with `status` equal to `sent`. Evidence MUST record the non-secret chat
   UID plus the sent message UID/body/status, and MUST NOT record the token.

4. Token hygiene MUST be clean. The Plow token value from `state.json` MUST NOT
   appear in argv, generated logs, committed files, dashboard text, or the
   install evidence:

   ```bash
   token="$(jq -r '.token' "<HOME>/.claude/plow-chat/state.json")"
   test -n "$token"
   ! pgrep -af "$token"
   ! grep -R -- "$token" "<HOME>/.claude/run" 2>/dev/null
   ! git grep -F -- "$token"
   ```
