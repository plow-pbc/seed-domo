# Testing

## Automated E2E

Run the committed install repro:

```bash
ref/installer/e2e-install.sh
```

It runs a solo install and a group install with two members. Both enter through
the live install action, `ref/installer/domo-install.sh`, against the local Plow
stub. The runner asserts:

- the installer reaches `ready=true`;
- the daemon is alive;
- the real `ref/channels/plow-chat/server.ts` receives a stub WSS inbound
  `message_received` frame, emits the Claude channel notification, and sends an
  outbound reply through its real `reply` tool (`POST /v1/chats/{uid}/messages`);
- the Plow API call sequence matches the solo/group path;
- `.claude/plow-chat/state.json` is chmod 600 and contains exactly
  `{base_url, token, chat_uid}`;
- the final install state reflects the chosen solo/group activation.

Coverage gap: the E2E uses a fake Claude CLI for deterministic login/preflight
and a direct MCP client as the Claude host for the channel round-trip. It proves
the install action, Plow stub, real channel server inbound delivery, and real
reply send path. It does not prove Claude Code's proprietary host loads the MCP
registration or that an LLM chooses to call `reply`.

## Plow Stub

Run the stub by hand:

```bash
PLOW_STUB_STATE_DIR=/tmp/domo-plow-stub bun run ref/installer/plow-stub.ts
base_url="$(jq -r .base_url /tmp/domo-plow-stub/server-info)"
```

Then point an install at it:

```bash
PLOW_CHAT_BASE_URL="$base_url" ref/installer/domo-install.sh
```

The stub exposes `/v1/auth/activate`, `/v1/auth/activate/redeem`,
`/v1/lines`, `/v1/chats`, `/v1/ws/ticket`, and `/v1/ws?ticket=...`.
Use `POST /_stub/text` with an exact activation or `VERIFY-*` code to simulate
a phone text, and `GET /_stub/calls` to inspect counters and ordered call
sequence.

## Dashboard Manual Smoke

1. Start a fresh install through the SEED path or directly through the live
   driver for local smoke:

   ```bash
   ref/installer/domo-install.sh
   ```

2. Confirm the dashboard opens quickly after the tooling check.

3. Before answering the terminal question, confirm the dashboard banner says:

   ```text
   One quick question is waiting in your terminal — answer it to continue.
   ```

4. Confirm the login and Calendar rows appear immediately:

   - login row shows the exact `domo login` command and says to run it in a new
     terminal;
   - Calendar row links to `https://claude.ai/customize/connectors`.

5. Answer the terminal question:

   ```text
   solo
   ```

   or:

   ```text
   group: Pat, Riley
   ```

6. Confirm activation rows appear:

   - solo shows one code/number row for `You`;
   - group shows the owner row, then one row per household member.

7. Complete the activation by texting the displayed code(s). For local stub
   smoke, post exact codes to `/_stub/text`.

8. Confirm activation rows flip to verified independently and the Plow step
   becomes complete only after all required rows are verified.

9. Confirm the ready state shows:

   ```text
   Domo is live - text <number> to talk to it.
   ```

10. Confirm the terminal reports success and `ref/domo status` shows the daemon
    alive with `plow-chat state: present` and no token value printed.
