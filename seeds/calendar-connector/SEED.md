# Purpose

> See [README#Purpose](../../README.md#purpose).

## Dependencies

This slice verifies that the same Anthropic account used by Domo's isolated
Claude instance has the claude.ai Google Calendar connector connected. It
produces no durable account artifact; success is a strict in-session probe
against the real account.

Hard dependencies:

- **Claude instance slice** - `<HOME>/.claude` MUST already be logged in by
  `seeds/claude-instance/SEED.md` with first-party `claude.ai` subscription auth.
- **Claude Code CLI** - `claude` MUST be on `PATH`.
- **claude.ai Google Calendar connector** - the user MUST be able to connect it
  at `https://claude.ai/customize/connectors` for the same Anthropic account.
- **`jq`** - generated verification helpers MUST use it for strict stream-json
  parsing.
- **`perl`** - generated helpers MUST use it for alarm-based command timeouts.

The installing agent MUST resolve the Domo home once before generation,
defaulting to `$HOME/.domo` for user installs. Auth-dependent rehearsals use the
stable baked path. Generated runtime files MUST embed that literal path and MUST
NOT read `DOMO_HOME` at runtime.

## Objects

- **Baked Domo home** - the absolute install home selected before generation.
  Calendar verification reads the already-authenticated Claude config at
  `<HOME>/.claude` and writes non-secret probe logs under that config.
- **Isolated Claude config dir** - `<HOME>/.claude`, passed as
  `CLAUDE_CONFIG_DIR` while unsetting metered-key environment variables.
- **Calendar workspace** - `<HOME>/runtime/calendar-connector/workspace`, the
  generated probe working directory.
- **Calendar runtime dir** - `<HOME>/runtime/calendar-connector`, containing
  generated executable helpers:
  - `check` - runs one real connector probe and exits 0 only on `CONNECTED`;
  - `wait` - polls `check` until `CONNECTED` or timeout;
  - `parse-transcript` - parses a stream-json transcript and prints
    `CONNECTED` or `PENDING`.
- **Probe output logs** - non-secret stream-json stdout/stderr files under
  `<HOME>/.claude/run/calendar-connector/`.
- **Text-only transcript fixture** - a generated verification fixture under
  `<HOME>/runtime/calendar-connector/fixtures/text-only.jsonl`; it MUST parse
  as `PENDING`.

## Actions

### Calendar connector verifier is generated

The installing agent MUST generate this slice into the baked Domo home. It MUST
NOT copy `ref/domo-calendar-piece.sh` or depend on any committed Calendar script.

1. Resolve the baked home to an absolute path. Create:

   ```text
   <HOME>/runtime/calendar-connector
   <HOME>/runtime/calendar-connector/workspace
   <HOME>/runtime/calendar-connector/fixtures
   <HOME>/.claude/run/calendar-connector
   ```

2. Generate `parse-transcript`. It MUST read a Claude stream-json transcript
   path and return `CONNECTED` only when a real Calendar `tool_use` has a
   matching non-error `tool_result` with the same `tool_use_id`.

   The probed tool name is exactly:

   ```text
   mcp__claude_ai_Google_Calendar__list_calendars
   ```

   The parser MUST:

   - collect tool-use IDs only from assistant messages whose content item has
     `type == "tool_use"` and `name == "mcp__claude_ai_Google_Calendar__list_calendars"`;
   - collect tool results only from user messages whose content item has
     `type == "tool_result"`;
   - require the result's `tool_use_id` to be one of the collected Calendar
     tool-use IDs;
   - require `is_error != true`;
   - accept a result as substantive only if it has
     `tool_use_result.structuredContent.calendars` as an array, JSON content
     with a top-level `calendars` array, or text length greater than 2 that
     does not match the errorish regex below;
   - otherwise print `PENDING` and exit nonzero.

   The generated parser MUST include this errorish regex:

   ```text
   permission denied|not found|failed|error|missing|unauthorized|requires authentication|connect
   ```

3. Generate `check`. It MUST first verify that the isolated Claude config is
   logged in with:

   ```bash
   env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN \
     CLAUDE_CONFIG_DIR="<HOME>/.claude" \
     claude auth status --json
   ```

   It MUST proceed only when the auth-status command exits `rc == 0` and that
   JSON satisfies:

   ```text
   rc == 0
   loggedIn == true
   authMethod == "claude.ai"
   apiProvider == "firstParty"
   ```

   It MUST then run this real probe from
   `<HOME>/runtime/calendar-connector/workspace`:

   ```bash
   env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN \
     CLAUDE_CONFIG_DIR="<HOME>/.claude" \
     claude -p --verbose --output-format stream-json \
       --permission-mode auto \
       --max-budget-usd 0.50 \
       "Call mcp__claude_ai_Google_Calendar__list_calendars now. After the tool result returns, summarize the number of calendars. Do not claim success unless the tool result is available."
   ```

   The probe command MUST be bounded by a 90-second timeout. `check` MUST write
   stdout and stderr to timestamped files under
   `<HOME>/.claude/run/calendar-connector/`, then invoke `parse-transcript` on
   the stdout file. It exits 0 only when the parser reports `CONNECTED`; it
   exits nonzero and reports `PENDING` or `NOT_CONNECTED` otherwise.

4. Generate `wait`. It MUST run `check` every 5 seconds until `check` exits 0 or
   a 600-second timeout expires. It MUST print the connector URL
   `https://claude.ai/customize/connectors` while waiting so the installing
   agent can direct the user to connect Google Calendar if needed.

5. Generate `fixtures/text-only.jsonl`, a stream-json transcript containing only
   text content and no Calendar tool-use/result pair. It MUST parse as
   `PENDING`.

If this slice's `## Verification` fails because a generated helper, parser, or
fixture is wrong, the installing agent MUST regenerate this slice exactly once
and rerun Verification. If the rerun still fails, stop the install, write the
terminal reason to repo-root `install-report.json`, and do not attempt a third
generation.

## Verification

Verification runs against the just-generated real instance and generated files.

1. The generated runtime files MUST exist and be executable:

   ```bash
   test -x "<HOME>/runtime/calendar-connector/check"
   test -x "<HOME>/runtime/calendar-connector/wait"
   test -x "<HOME>/runtime/calendar-connector/parse-transcript"
   test -d "<HOME>/runtime/calendar-connector/workspace"
   test -f "<HOME>/runtime/calendar-connector/fixtures/text-only.jsonl"
   ```

2. No generated file in `<HOME>/runtime/calendar-connector` MAY contain a
   runtime read of `DOMO_HOME`; all generated paths MUST be baked absolute paths.

3. Metered-key immunity MUST be visible on every generated Claude launch path.
   With `ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN` set to sentinel values
   in the parent environment, the generated `check` helper MUST still invoke
   Claude through `env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN`. The
   sentinel fake-Claude binary and its logs MUST be created in a scratch
   directory outside `<HOME>/runtime/calendar-connector` and
   `<HOME>/.claude/run/calendar-connector`, then removed after the drill.

4. The generated `check` helper MUST run against the real Google Calendar
   connector on the isolated Claude account and report `CONNECTED` only when
   `parse-transcript` finds a strict
   `tool_use` -> `tool_result` match by `tool_use_id` for
   `mcp__claude_ai_Google_Calendar__list_calendars`. The stored probe transcript
   path MUST be recorded in rehearsal evidence.

5. Re-running `parse-transcript` on the real stored probe transcript from item 4
   MUST report `CONNECTED` and exit 0.

6. Running `parse-transcript` on the generated text-only transcript fixture MUST
   print `PENDING` and exit nonzero:

   ```bash
   "<HOME>/runtime/calendar-connector/parse-transcript" \
     "<HOME>/runtime/calendar-connector/fixtures/text-only.jsonl"
   ```

7. The generated parser MUST contain the strict Calendar tool name, the
   `tool_use_id` matching check, and the errorish regex:

   ```bash
   parser="<HOME>/runtime/calendar-connector/parse-transcript"
   grep -F 'mcp__claude_ai_Google_Calendar__list_calendars' "$parser"
   grep -F 'tool_use_id' "$parser"
   grep -F 'permission denied|not found|failed|error|missing|unauthorized|requires authentication|connect' "$parser"
   ```

8. The generated `wait` helper MUST contain the pinned 5-second poll interval
   and 600-second timeout:

   ```bash
   grep -F 'POLL_INTERVAL_SECONDS=5' "<HOME>/runtime/calendar-connector/wait"
   grep -F 'WAIT_TIMEOUT_SECONDS=600' "<HOME>/runtime/calendar-connector/wait"
   ```

9. The generated `check` helper MUST contain the pinned probe controls and exact
   prompt:

   ```bash
   check="<HOME>/runtime/calendar-connector/check"
   grep -F 'PROBE_TIMEOUT_SECONDS=90' "$check"
   grep -F -- '--permission-mode auto' "$check"
   grep -F -- '--max-budget-usd 0.50' "$check"
   grep -F 'Call mcp__claude_ai_Google_Calendar__list_calendars now. After the tool result returns, summarize the number of calendars. Do not claim success unless the tool result is available.' "$check"
   ```
