# Purpose

> See [README#Purpose](../../README.md#purpose).

## Dependencies

This slice activates Domo with Plow Chat, either as a solo chat or as a group
chat, and writes the local channel state consumed by later slices.

Hard dependencies:

- **Plow Chat contract SEED** - the installing agent MUST clone
  `https://github.com/plow-pbc/seed-plow-chat` from `origin/main` before
  generation, verify the clone contains baseline commit
  `fe24c9a53af1c9aeea5511cc6c1a797a2b770296` in its history, record the actual
  `git rev-parse HEAD`, and read that SEED's
  `## Objects` and `## Actions` as the only Plow API surface. This Domo SEED
  MUST NOT restate Plow endpoints, payload schemas, response schemas, or frame
  schemas.
- **Plow Chat API account** - the user MUST be able to complete the contract's
  activation flow. User installs use the contract's production base URL; dev
  rehearsals bake the local Plow base URL before generation.
- **`curl`** - generated helpers use it for Plow HTTP calls.
- **`jq`** - generated helpers use it for strict JSON construction and checks.
- **`bun`** - generated group activation uses it to open the WebSocket listener
  required before member codes are revealed.

The installing agent MUST resolve the Domo home once before generation,
defaulting to `$HOME/.domo` for user installs. Dev rehearsals use the stable
auth'd home only when the rehearsal is part of a full install walk. Generated
runtime files MUST embed that literal path and MUST NOT read `DOMO_HOME` at
runtime.

## Objects

- **Baked Domo home** - the absolute install home selected before generation.
  This slice writes only under that home.
- **Plow activation runtime dir** - `<HOME>/runtime/plow-activation`,
  containing generated executable helpers:
  - `activate` - runs solo or group activation;
  - `status` - validates and prints non-secret local activation status;
  - `cleanup` - invokes the contract's delete-chat behavior for the stored chat
    and removes local Plow activation state only after the remote chat is gone.
- **Plow local state dir** - `<HOME>/.claude/plow-chat`, chmod 700.
- **Plow channel state** - `<HOME>/.claude/plow-chat/state.json`, chmod 600,
  exactly `{base_url, token, chat_uid}` with sorted keys. `chat_uid` MUST start
  with `cht_`. The token MUST never be printed, logged, passed in argv, or
  committed.
- **Activation scratch state** - a private chmod-600 file under
  `<HOME>/.claude/plow-chat` that stores the contract's activation secret and
  non-secret display values until activation is complete. It MUST be removed
  after successful state write or cleanup.
- **Install state** - `<HOME>/install-state.json`, chmod 600. This slice owns
  `interview.mode`, `interview.members`, `activation`, and
  `activation_detail`.
- **Solo activation detail** - `activation_detail.mode == "solo"` plus the
  non-secret display values needed for the install dashboard and rehearsal
  evidence: `base_url`, `status`, `display_code`, `activation_message`,
  `send_to`, and the contract line identifier when available.
- **Group activation detail** - `activation_detail.mode == "group"` plus owner
  activation status, selected line, chat object, participant display names,
  one-time member verification codes, per-member status, and `chat_active`.
  The group token MAY be held there only while the file remains chmod 600.

## Actions

### Plow activation runtime is generated

The installing agent MUST generate this slice into the baked Domo home. It MUST
NOT copy or depend on any committed activation script.

1. Clone `https://github.com/plow-pbc/seed-plow-chat` from `origin/main` into a
   scratch directory and read its `## Objects` and `## Actions` before writing
   any helper. Treat that SEED as the only source for Plow calls, payloads,
   responses, and WebSocket frames.
2. Resolve the baked home and Plow base URL before generation. Create:

   ```text
   <HOME>/runtime/plow-activation
   <HOME>/.claude/plow-chat
   ```

3. Generate `activate`, `status`, and `cleanup` as chmod-700 executable files.
   They MUST contain the baked absolute `<HOME>` and baked Plow base URL as
   literals. They MUST NOT read `DOMO_HOME` or `PLOW_CHAT_BASE_URL` at runtime.
4. Generated helpers that send Bearer-authenticated Plow requests MUST pass the
   token through a chmod-600 `curl --config` tempfile and request bodies through
   stdin. A token MUST NOT appear in argv, logs, dashboard text, committed
   files, or rehearsal logs.
5. Generated helpers MUST use these pinned timing values:

   ```text
   REDEEM_POLL_INTERVAL_SECONDS=3
   REDEEM_TIMEOUT_SECONDS=300
   WSS_LISTEN_TIMEOUT_MS=300000
   ```

6. If this slice's `## Verification` fails because a generated helper or state
   writer is wrong, the installing agent MUST regenerate this slice exactly once
   and rerun Verification. If the rerun still fails, stop the install, write
   terminal `failure` with the reason to the repo-root `install-report.json`,
   and do not attempt a third generation.

### Domo is activated as a solo chat

The `activate --solo` helper MUST perform the contract's activation-with-first-
chat flow using `provision_chat` by name as Domo's solo knob. This SEED does
not define that API shape; it only owns these Domo-side requirements:

1. Surface the exact instruction text `Plow Activate: <display_code>` and the
   contract's send-to number to the installing agent and install dashboard.
   The user MUST text the full string. A bare code MUST fail.
2. Poll redeem every 3 seconds for up to 300 seconds until the contract reports
   verified. Timeout exits 75.
3. On success, write `<HOME>/.claude/plow-chat/state.json` chmod 600 and exactly
   `{base_url, token, chat_uid}` with sorted keys, where `chat_uid` starts with
   `cht_`.
4. Write `<HOME>/install-state.json` chmod 600 with
   `activation == "complete"` and a solo `activation_detail`.
5. Remove activation scratch state after success.

### Domo is activated as a group chat

The `activate --group <member-name>...` helper MUST perform the contract's
activate-before-chat-creation flow. This SEED does not define the API shape; it
only owns the Domo-side election, resume behavior, and member-verification UX.

1. Group mode MUST be elected in this slice, not by the root SEED. The
   generated helper MUST reject `activate --group` with no member names.
2. A valid solo `state.json` MUST NOT short-circuit a requested group
   activation. Idempotency is mode-specific: existing state may skip work only
   when `state.json` and `install-state.json` match the requested mode.
3. Owner activation MUST surface the full `Plow Activate: <display_code>` text,
   not a bare code, and poll redeem at the pinned cadence.
4. After owner verification, create the group chat according to the contract and
   immediately persist the returned one-time member codes into chmod-600
   `install-state.json`.
5. Before revealing any member `VERIFY-` code to the user or dashboard, open the
   contract's WebSocket subscription for the chat. Codes are revealed only after
   the listener is up.
6. During activation, ignore `connected` frames. In this slice they are not
   proof of readiness; only participant verification and chat-active evidence
   advance group activation. MUST NOT unify this rule with the later channel
   server: the channel server treats the same frame name as liveness, the
   opposite of activation.
7. When a participant-verification event arrives, immediately persist that
   participant's verified status. When the chat becomes active, write
   `state.json`, set `activation == "complete"`, and preserve the one-time codes
   already written to `install-state.json`.
8. Restart MUST resume from `install-state.json` without re-creating the chat or
   rotating member codes.
9. Before `--force` or a solo/group mode switch discards or overwrites a valid
   `state.json`, the helper MUST best-effort invoke the contract's delete-chat
   behavior for the prior chat and record the outcome in chmod-600
   `install-state.json`. Failure to delete the prior chat MUST be visible in the
   recorded outcome, but MUST NOT print the token.
10. WebSocket listen timeout exits 68.

### Plow chat is cleaned up

The `cleanup` helper is the Domo-owned usage point for the contract's delete-
chat behavior. It MUST read the local state file, invoke the contract's
server-side chat teardown for that chat, confirm the chat is gone or already
absent, then remove only local Plow activation state. It MUST redact any copied
token and delete `member_codes` from `install-state.json` after teardown. It
MUST NOT reset, logout, remove, or overwrite the baked Domo home.

## Verification

Verification runs against the just-generated real instance. It is live operator
evidence plus the thin self-checks needed to decide whether this slice passes.

1. The generated runtime files exist under the baked home and are executable:

   ```bash
   test -x "<HOME>/runtime/plow-activation/activate"
   test -x "<HOME>/runtime/plow-activation/status"
   test -x "<HOME>/runtime/plow-activation/cleanup"
   test -d "<HOME>/.claude/plow-chat"
   ```

2. Generated files in `<HOME>/runtime/plow-activation` contain the baked home
   and selected Plow base URL as literals and do not read `DOMO_HOME` or
   `PLOW_CHAT_BASE_URL` at runtime.

3. Generation records the fresh `seed-plow-chat` clone path and actual
   `origin/main` commit. The clone contains baseline commit
   `fe24c9a53af1c9aeea5511cc6c1a797a2b770296`, and Domo-side generated code
   follows that contract for Plow calls instead of declaring an independent API
   surface.

4. Solo activation against the selected Plow base URL shows the full
   `Plow Activate: <code>` instruction and send-to number, rejects a bare code,
   and succeeds only when the full instruction is texted.

5. After solo success, `<HOME>/.claude/plow-chat/state.json` is chmod 600 and
   strictly shaped:

   ```bash
   state="<HOME>/.claude/plow-chat/state.json"
   test "$(stat -f '%Lp' "$state" 2>/dev/null || stat -c '%a' "$state")" = 600
   jq -e 'type == "object"
     and (keys == ["base_url","chat_uid","token"])
     and (.base_url | type == "string" and length > 0)
     and (.token | type == "string" and length > 0)
     and (.chat_uid | type == "string" and startswith("cht_"))' "$state"
   ```

6. Group activation against the selected Plow base URL shows the group election,
   verifies the owner with the full activation instruction, reveals member
   `VERIFY-` codes only after the WebSocket listener is up, verifies each member,
   and finishes with `activation_detail.chat_active == true`.

7. Restart-resume preserves the original group chat and member codes. Evidence
   shows the chat UID plus all `VERIFY-` codes in `<HOME>/install-state.json`
   remain unchanged across the resumed generated activation run.

8. Mode-switch and force cleanup protect against orphaning the prior chat. Before
   generated activation overwrites a valid prior solo or group state, it records a
   prior-chat cleanup outcome in `<HOME>/install-state.json`, and the prior
   server-side chat is gone or already absent.

9. Token hygiene is clean. No Bearer token appears in argv, generated logs,
   committed files, dashboard text, or install evidence. The token value from
   `state.json` is not found outside chmod-600 activation state.

10. Cleanup invokes the contract's delete-chat behavior for the stored chat.
    After generated `cleanup` exits 0, the server-side chat is gone or already
    absent, local `state.json` is removed, and `activation_detail.token` plus
    `activation_detail.member_codes` are absent from `<HOME>/install-state.json`.
