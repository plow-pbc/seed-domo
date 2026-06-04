# Testing

## Automated E2E

Run the committed piece verification repro:

```bash
ref/installer/e2e-install.sh
```

It runs the deterministic checks available without a real Claude subscription or
SMS provider:

- `bash ref/verify.sh` for structural SEED conformance;
- `ref/domo-activate-piece.sh selftest` for Plow activation mechanics against the
  local stub;
- `ref/domo-ready-piece.sh selftest` for config authoring, channel connection,
  daemon startup, and the first ready text against the local stub.

Coverage gap: the E2E uses a fake Claude CLI for deterministic login/preflight
and a direct MCP client as the Claude host for the channel round-trip. It proves
the Plow stub, real channel server inbound delivery, and real reply send path.
It does not prove a human completed the SEED action, Claude Code's proprietary
host loads the MCP registration, or that an LLM chooses to call `reply`.

## Plow Stub

Run the stub by hand:

```bash
PLOW_STUB_STATE_DIR=/tmp/domo-plow-stub bun run ref/installer/plow-stub.ts
base_url="$(jq -r .base_url /tmp/domo-plow-stub/server-info)"
```

Then point the activation or ready piece at it with the same Domo home the SEED
action is using:

```bash
DOMO_HOME="$HOME/.domo" PLOW_CHAT_BASE_URL="$base_url" ref/domo-activate-piece.sh activate
```

The stub exposes `/v1/auth/activate`, `/v1/auth/activate/redeem`,
`/v1/lines`, `/v1/chats`, `/v1/ws/ticket`, and `/v1/ws?ticket=...`.
Use `POST /_stub/text` with an exact activation or `VERIFY-*` code to simulate
a phone text, and `GET /_stub/calls` to inspect counters and ordered call
sequence.

## Dashboard Manual Smoke

1. Start a fresh install through the SEED path:

   ```bash
   export DOMO_HOME="$HOME/.domo"
   ```

2. Launch the display-only dashboard as described in `SEED.md` Phase 0.

3. Confirm the login and Calendar rows appear immediately:

   - login row shows the exact
     `DOMO_HOME="$HOME/.domo" ref/domo-login-piece.sh login` command and says to
     run it in a new terminal;
   - Calendar row links to `https://claude.ai/customize/connectors`.

4. Complete Claude login and Calendar connector setup, then confirm both rows
   flip to complete only after the corresponding piece reports success.

5. Confirm the activation row appears with one code/number row for `You`.

6. Complete the activation by texting the displayed code. For local stub smoke,
   post the exact code to `/_stub/text`.

7. Confirm the activation row flips to verified and the Plow step becomes
   complete only after the activation piece reports `VERIFIED`.

8. Confirm the ready state shows:

   ```text
   Domo is live - check your phone for the ready text.
   ```

9. Confirm the terminal reports success and `ref/domo-ready-piece.sh status`
   shows the daemon alive with `plow-chat state: present` and no token value
   printed.
