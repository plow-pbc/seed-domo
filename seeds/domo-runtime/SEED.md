# Purpose

> See [README#Purpose](../../README.md#purpose).

## Dependencies

This slice authors the Domo runtime workspace, registers the Plow chat channel,
starts the persistent Claude daemon on one pinned session, sends the first ready
text, and writes the operator entrypoint at `<HOME>/bin/domo`.

Hard dependencies:

- **Claude instance slice** - `<HOME>/.claude` MUST already be logged in by
  `seeds/claude-instance/SEED.md` with first-party `claude.ai` subscription auth.
- **Calendar connector slice** - the same Claude account MUST already have the
  Google Calendar connector verified by `seeds/calendar-connector/SEED.md`.
- **Plow activation slice** - `<HOME>/.claude/plow-chat/state.json` and
  `<HOME>/install-state.json` MUST already be written by
  `seeds/plow-activation/SEED.md`.
- **Plow Chat channel server** - during the dual-era conversion, this runtime
  MAY bake the absolute path to the monolith channel server at
  `ref/channels/plow-chat`. The later `plow-channel-server` slice replaces that
  with generated channel output.
- **Claude Code CLI** - `claude` MUST be on `PATH`.
- **`bun`** - used by the Plow chat channel server and the direct MCP ready-text
  sender.
- **`jq`** - used for strict JSON checks and transcript rendering.
- **`expect`** - used by the generated PTY wrapper to answer the Claude
  development-channel confirmation and keep the daemon alive.

The installing agent MUST resolve the Domo home once before generation,
defaulting to `$HOME/.domo` for user installs. Dev rehearsals use the stable
auth'd home `~/.domo-rehearsal` only for auth-dependent full runtime checks.
Generated runtime files MUST embed that literal path and MUST NOT read
`DOMO_HOME` at runtime.

`ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN` MUST be unset for every
generated `claude` invocation in this slice.

## Objects

- **Baked Domo home** - the absolute install home selected before generation.
  This slice writes runtime artifacts only under that home.
- **Domo runtime dir** - `<HOME>/runtime/domo-runtime`, containing generated
  executable helpers:
  - `author` - writes workspace prompt/config and pinned session metadata;
  - `register-channel` - registers the `plow-chat` MCP server in the isolated
    Claude config;
  - `start` - starts the persistent daemon and runs the host-log readiness gate;
  - `ready` - runs `start`, then sends the first ready text out of band through
    a direct MCP client;
  - `send-ready` - sends the configured ready text through the channel `reply`
    tool without treating that send as readiness proof;
  - `status` - prints non-secret runtime state and can assert green status;
  - `logs` - renders the pinned-session transcript or stripped raw daemon log;
  - `stop` - stops the daemon by PID and tree-kills the scoped session
    signature plus channel children;
  - `doctor` - runs read-only preflight checks;
  - `reset` - delegates Plow cleanup and Claude logout, then removes the baked
    home only behind `safe_remove` guards;
  - `readiness-gate` - a separately executable gate used by `start` and
    Verification to prove host MCP registration from a fresh log snapshot.
- **Operator CLI** - `<HOME>/bin/domo`, chmod 700. This is the user-facing
  entrypoint and contains only baked absolute paths. It MUST NOT read
  `DOMO_HOME` at runtime. It dispatches to the generated runtime helpers for
  `start`, `ready`, `status`, `logs`, `stop`, `doctor`, and `reset`.
- **Domo workspace** - `<HOME>/workspace`, containing generated `CLAUDE.md`.
  The prompt MUST match solo or group mode from `<HOME>/install-state.json` and
  include group member display names when group mode is active.
- **Pinned session metadata** - `<HOME>/.claude/domo.json`, chmod 600, containing
  `session_id`, `channel`, and `created`. `session_id` is the single persistent
  session used by daemon starts.
- **Runtime config** - `<HOME>/.claude/domo-runtime.json`, chmod 600, containing
  non-secret runtime configuration including `session_id`, `channel`, `mode`,
  `ready_text`, and the generated system prompt.
- **Daemon run dir** - `<HOME>/.claude/run`, containing PID, signature, raw log,
  readiness snapshots, and the ready-send result. These files MUST NOT contain
  the Plow Bearer token.
- **Plow channel state** - `<HOME>/.claude/plow-chat/state.json`, chmod 600,
  read from the activation slice and validated by this slice. The token MUST
  never be printed, logged, passed in argv, or committed.
- **Host MCP log root** - the Claude host log tree that contains
  `mcp-logs-plow-chat` jsonl files for the workspace slug. The readiness gate
  reads only fresh bytes appended after a captured snapshot.
- **Default ready text** - exactly
  `Domo is ready. Text me here when you need help with the household or calendar.`

## Actions

### Domo runtime is generated

The installing agent MUST generate this slice into the baked Domo home. It MUST
NOT copy `ref/domo`, `ref/domo-ready-piece.sh`, or depend on any committed
runtime script as the installed operator entrypoint.

1. Resolve the baked home, the absolute Domo checkout path, and the absolute
   Plow channel server path before generation. Create:

   ```text
   <HOME>/bin
   <HOME>/runtime/domo-runtime
   <HOME>/workspace
   <HOME>/.claude/run
   ```

2. Generate every helper in `<HOME>/runtime/domo-runtime` and the operator
   entrypoint `<HOME>/bin/domo` as chmod-700 executable files. Each generated
   file MUST contain the baked absolute `<HOME>` literal. Generated files MUST
   NOT read `DOMO_HOME` or use repo-relative path discovery at runtime.

3. Generate `author` so it reads `<HOME>/install-state.json`, writes
   `<HOME>/workspace/CLAUDE.md`, ensures `<HOME>/.claude/domo.json`, and writes
   `<HOME>/.claude/domo-runtime.json`. The solo prompt MUST describe a solo
   household. The group prompt MUST describe a group household and include the
   verified member display names from install state.

4. Generate the pinned-session rule exactly: if the session jsonl exists under
   the workspace projects directory, launch Claude with `--resume <session_id>`;
   otherwise launch with `--session-id <session_id>`. The generated launch path
   MUST never pass both flags in one invocation.

5. Generate the daemon launch argv with these pinned strings:

   ```text
   --dangerously-load-development-channels server:plow-chat
   --permission-mode auto
   --append-system-prompt
   ```

   The generated default MUST NOT use `bypassPermissions`, and this slice MUST
   NOT add a custom PreToolUse allowlist.

6. Generate the PTY wrapper path. When `expect` is available, daemon launch MUST
   use the generated spawn-confirm wrapper that answers the development-channel
   confirmation and keeps the session alive. The confirmation matcher MUST use
   the same stable labels as the Claude instance slice: `Yes, try it` sends `2`;
   text-style/theme/trust/dev-channel labels press Enter. If a fallback PTY path
   is generated, it MUST be explicit in `doctor` output and still keep the same
   launch argv.

7. Generate `register-channel` to run, under the isolated Claude config:

   ```bash
   claude mcp remove plow-chat
   claude mcp add plow-chat --scope user -- bun run --cwd "<CHANNEL_DIR>" --shell=bun --silent start
   ```

   In the dual-era conversion, `<CHANNEL_DIR>` MAY be the baked absolute
   `ref/channels/plow-chat` path from this checkout.

8. Generate the readiness gate as snapshot -> delta -> sessionId match. `start`
   MUST snapshot the host MCP log files immediately before daemon launch, then
   accept readiness only when the appended delta contains both:

   ```text
   "sessionId":"<session_id>"
   Channel notifications registered
   ```

   The gate MUST reject:

   - a matching line that existed before the snapshot;
   - a `Channel notifications registered` line for another session;
   - any post-snapshot `Channel notifications skipped` line for the pinned
     session;
   - timeout before the pinned registration line arrives.

   The timeout is exactly `START_READY_TIMEOUT_SECONDS=60`.

9. Generate the two-layer readiness behavior. A connected marker or transcript
   jsonl may be used only as a short diagnostic fallback while waiting for the
   host log. It MUST NOT mark the daemon ready. The host MCP log registration
   gate is authoritative.

10. Generate `send-ready` as a direct MCP client that starts the Plow channel
    server with `PLOW_CHAT_STATE=<HOME>/.claude/plow-chat/state.json` and calls
    the `reply` tool with the default ready text. `ready` MUST call `send-ready`
    only after the host-log readiness gate succeeds. A sent ready text is never
    proof that the daemon is ready.

11. Generate `status` and `doctor` to validate non-secret runtime state:
    subscription auth is confirmed, metered keys are unset for generated Claude
    paths, Plow state exists and is chmod 600, the pinned session is present,
    the permission mode is `auto`, and the daemon PID/signature state is
    consistent. They MUST never print the Plow token.

12. Generate `logs` to restore terminal state on exit. It MUST run `stty sane`
    when possible, reset common terminal modes, and pass raw daemon logs through
    `strip_ansi` before printing. Transcript rendering MUST use the pinned
    session jsonl when present and MUST avoid printing secrets.

13. Generate `stop` to stop the wrapper PID, then tree-kill by the recorded
    scoped signature derived from the pinned session id. It MUST also sweep
    channel-server child processes by the baked channel server path. It MUST NOT
    match only a generic process name.

14. Generate `reset` as an ordered teardown:

    ```text
    stop daemon
    <HOME>/runtime/plow-activation/cleanup
    <HOME>/runtime/claude-instance/logout
    confirm auth status is loggedIn=false
    safe_remove <HOME>
    ```

    `reset` consumes those other slices' cleanup/logout helpers and MUST NOT
    re-implement Plow delete-chat behavior or Claude logout behavior. The
    generated `safe_remove` MUST refuse an empty path, `/`, `$HOME`, and any
    path that contains this SEED checkout.

15. Generate `<HOME>/bin/domo` as a thin baked-path dispatcher. It MUST contain
    literal paths to `<HOME>/runtime/domo-runtime/<helper>` and MUST NOT derive
    the runtime home from its own location, `DOMO_HOME`, `PWD`, or the caller's
    environment.

If this slice's `## Verification` fails because a generated helper or CLI is
wrong, the installing agent MUST regenerate this slice exactly once and rerun
Verification. If the rerun still fails, stop the install, write terminal
`failure` with the reason to the repo-root `install-report.json`, and do not
attempt a third generation.

### Domo is started and made ready

The installing agent runs:

```bash
<HOME>/bin/domo ready
```

The generated CLI authors workspace config, registers the channel, starts the
daemon on the pinned session, waits for the authoritative host MCP log
registration line, and only then sends the first ready text through the Plow
`reply` tool.

The user install E2E is the real phone receiving the default ready text. The dev
rehearsal E2E is the same ready text landing in the local Plow chat.

### Domo runtime is reset

`<HOME>/bin/domo reset` is destructive and MUST be guarded. Normal install
verification MUST NOT run reset against `~/.domo-rehearsal` because that stable
home holds reusable auth and calendar state. Reset/logout evidence for
auth-dependent rehearsals MUST use either:

- an ephemeral no-auth home; or
- a sentinel fake-`claude` shim in a scratch `PATH` that records the logout
  invocation without touching real stable-home auth.

The reset check is successful only when the generated reset path invokes the
plow-activation `cleanup` helper and the claude-instance `logout` helper in
order before local removal. It MUST NOT delete, logout, or full-reset the stable
`~/.domo-rehearsal` home.

## Verification

Verification runs against the just-generated real instance and generated files.

1. The generated runtime files MUST exist and be executable:

   ```bash
   for helper in author register-channel readiness-gate start ready send-ready status logs stop doctor reset; do
     test -x "<HOME>/runtime/domo-runtime/$helper"
     test "$(stat -f '%Lp' "<HOME>/runtime/domo-runtime/$helper" 2>/dev/null || stat -c '%a' "<HOME>/runtime/domo-runtime/$helper")" = 700
   done
   test -x "<HOME>/bin/domo"
   test "$(stat -f '%Lp' "<HOME>/bin/domo" 2>/dev/null || stat -c '%a' "<HOME>/bin/domo")" = 700
   ```

2. The generated metadata artifacts MUST exist, be private where applicable, and
   point at the pinned session:

   ```bash
   test -f "<HOME>/workspace/CLAUDE.md"
   test -f "<HOME>/.claude/domo.json"
   test -f "<HOME>/.claude/domo-runtime.json"
   test -d "<HOME>/.claude/run"
   test "$(stat -f '%Lp' "<HOME>/.claude/domo.json" 2>/dev/null || stat -c '%a' "<HOME>/.claude/domo.json")" = 600
   test "$(stat -f '%Lp' "<HOME>/.claude/domo-runtime.json" 2>/dev/null || stat -c '%a' "<HOME>/.claude/domo-runtime.json")" = 600
   jq -e '.session_id | type == "string" and length > 0' "<HOME>/.claude/domo.json"
   jq -e '.session_id | type == "string" and length > 0' "<HOME>/.claude/domo-runtime.json"
   ```

3. Every generated runtime artifact MUST contain baked absolute paths and no
   runtime `DOMO_HOME` reads:

   ```bash
   grep -R '<HOME>' "<HOME>/runtime/domo-runtime" "<HOME>/bin/domo"
   ! grep -R 'DOMO_HOME' "<HOME>/runtime/domo-runtime" "<HOME>/bin/domo"
   ! grep -R 'dirname.*BASH_SOURCE\\|pwd).*runtime\\|PWD' "<HOME>/bin/domo"
   ```

4. The generated operator CLI MUST be a baked dispatcher for all user-facing
   verbs:

   ```bash
   cli="<HOME>/bin/domo"
   grep -F '<HOME>/runtime/domo-runtime/start' "$cli"
   grep -F '<HOME>/runtime/domo-runtime/ready' "$cli"
   grep -F '<HOME>/runtime/domo-runtime/status' "$cli"
   grep -F '<HOME>/runtime/domo-runtime/logs' "$cli"
   grep -F '<HOME>/runtime/domo-runtime/stop' "$cli"
   grep -F '<HOME>/runtime/domo-runtime/doctor' "$cli"
   grep -F '<HOME>/runtime/domo-runtime/reset' "$cli"
   ```

5. The generated launch path MUST expose grep-visible gates for every pinned
   runtime string:

   ```bash
   author="<HOME>/runtime/domo-runtime/author"
   register="<HOME>/runtime/domo-runtime/register-channel"
   start="<HOME>/runtime/domo-runtime/start"
   gate="<HOME>/runtime/domo-runtime/readiness-gate"
   sender="<HOME>/runtime/domo-runtime/send-ready"
   logs="<HOME>/runtime/domo-runtime/logs"
   stop="<HOME>/runtime/domo-runtime/stop"
   reset="<HOME>/runtime/domo-runtime/reset"
   grep -F 'CLAUDE.md' "$author"
   grep -F 'domo.json' "$author"
   grep -F 'domo-runtime.json' "$author"
   grep -F 'claude mcp add plow-chat --scope user' "$register"
   grep -F 'bun run --cwd' "$register"
   grep -F -- '--dangerously-load-development-channels' "$start"
   grep -F 'server:plow-chat' "$start"
   grep -F -- '--permission-mode auto' "$start"
   grep -F -- '--append-system-prompt' "$start"
   grep -F -- '--session-id' "$start"
   grep -F -- '--resume' "$start"
   grep -F 'env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN' "$start"
   grep -F 'expect' "$start"
   grep -F 'Yes, try it' "$start"
   grep -F 'START_READY_TIMEOUT_SECONDS=60' "$gate"
   grep -F 'Channel notifications registered' "$gate"
   grep -F 'Channel notifications skipped' "$gate"
   grep -F '"sessionId":"' "$gate"
   grep -F 'Domo is ready. Text me here when you need help with the household or calendar.' "$sender"
   grep -F 'stty sane' "$logs"
   grep -F 'strip_ansi' "$logs"
   grep -F 'pkill -TERM -f' "$stop"
   grep -F '<HOME>/runtime/plow-activation/cleanup' "$reset"
   grep -F '<HOME>/runtime/claude-instance/logout' "$reset"
   grep -F 'safe_remove' "$reset"
   ! grep -R 'bypassPermissions\\|PreToolUse' "<HOME>/runtime/domo-runtime" "<HOME>/bin/domo"
   ```

6. Metered-key immunity MUST be visible on every generated Claude launch path.
   With `ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN` set to sentinel values
   in the parent environment, a sentinel fake-`claude` shim in a scratch `PATH`
   MUST record that generated helpers invoke Claude with both variables absent.
   The scratch shim and logs MUST live outside `<HOME>` and MUST be removed
   after evidence is captured.

7. The pinned-session launch rule MUST be exercised twice:

   ```bash
   # no jsonl exists
   "<HOME>/runtime/domo-runtime/author"
   "<HOME>/runtime/domo-runtime/doctor" --show-session-mode
   # evidence must show --session-id <sid> and not --resume

   # create the pinned jsonl fixture or use the real first daemon transcript
   "<HOME>/runtime/domo-runtime/doctor" --show-session-mode
   # evidence must show --resume <sid> and not --session-id
   ```

8. The readiness gate MUST accept only a post-snapshot registration line for the
   pinned session. Run the gate against scratch host-log directories, then
   against the real generated daemon:

   ```bash
   gate="<HOME>/runtime/domo-runtime/readiness-gate"
   "$gate" --fixture stale-registered --expect-fail
   "$gate" --fixture other-session-registered --expect-fail
   "$gate" --fixture pinned-session-skipped --expect-fail
   "$gate" --fixture pinned-session-post-snapshot-registered --expect-pass
   "<HOME>/bin/domo ready"
   ```

   The real daemon run MUST record the post-snapshot
   `Channel notifications registered` line for the pinned `session_id`.

9. Channel-connect plus ready-text round trip MUST land in the chat. In dev
   rehearsal, query the local Plow chat after `<HOME>/bin/domo ready` and record
   the non-secret chat UID plus the message containing exactly the default ready
   text. In a user install, the equivalent E2E is the user's phone receiving the
   ready text.

10. Solo and group workspace prompts MUST be authored correctly:

   ```bash
   grep -F 'solo household' "<HOME>/workspace/CLAUDE.md"
   # in a separate group rehearsal home or after group activation:
   grep -F 'group household' "<HOME>/workspace/CLAUDE.md"
   grep -F '<member-display-name>' "<HOME>/workspace/CLAUDE.md"
   ```

11. `status` and `doctor` MUST assert green after readiness without printing
    secrets:

    ```bash
    "<HOME>/bin/domo" status --assert
    "<HOME>/bin/domo" doctor
    token="$(jq -r '.token' "<HOME>/.claude/plow-chat/state.json")"
    test -n "$token"
    ! "<HOME>/bin/domo" status 2>&1 | grep -F -- "$token"
    ! "<HOME>/bin/domo" doctor 2>&1 | grep -F -- "$token"
    ```

12. `logs` MUST restore terminal state and strip raw TUI control bytes:

    ```bash
    grep -F 'stty sane' "<HOME>/runtime/domo-runtime/logs"
    grep -F 'strip_ansi' "<HOME>/runtime/domo-runtime/logs"
    "<HOME>/bin/domo" logs --raw --no-follow >/tmp/domo-logs-sample.txt
    ```

13. `stop` MUST tree-kill by scoped signature and sweep channel children without
    using generic process names:

    ```bash
    grep -F 'daemon_kill_pattern' "<HOME>/runtime/domo-runtime/stop"
    grep -F 'pkill -TERM -f' "<HOME>/runtime/domo-runtime/stop"
    grep -F '<CHANNEL_DIR>' "<HOME>/runtime/domo-runtime/stop"
    ```

14. `reset` MUST invoke delegated teardown in order and must not run against the
    stable rehearsal home. Evidence MUST be collected with a sentinel
    fake-`claude` shim or an ephemeral home:

    ```bash
    grep -n '<HOME>/runtime/plow-activation/cleanup' "<HOME>/runtime/domo-runtime/reset"
    grep -n '<HOME>/runtime/claude-instance/logout' "<HOME>/runtime/domo-runtime/reset"
    grep -n 'safe_remove' "<HOME>/runtime/domo-runtime/reset"
    ```

    The recorded reset drill MUST show cleanup before logout before
    `safe_remove`, and the stable `~/.domo-rehearsal` home MUST remain present.

15. Token hygiene MUST be clean. The Plow token value from `state.json` MUST NOT
    appear in argv, generated runtime files, daemon logs, status output, or
    rehearsal logs:

    ```bash
    token="$(jq -r '.token' "<HOME>/.claude/plow-chat/state.json")"
    test -n "$token"
    ! pgrep -af "$token"
    ! grep -R -- "$token" "<HOME>/runtime/domo-runtime" "<HOME>/bin/domo" "<HOME>/.claude/run" 2>/dev/null
    ! git grep -F -- "$token"
    ```

16. The install rehearsal per `docs/testing/e2e-rehearsal.md` MUST complete
    with a kept rehearsal log. The log MUST name the single installing agent for
    this slice attempt, record `git rev-parse HEAD` after the implementation
    commit, include the `bash ref/verify.sh` run, include scratch-dir evidence
    for negative drills, and include every Verification item above.
