# Purpose

> See [README#Purpose](../../README.md#purpose).

## Dependencies

This slice creates and verifies Domo's isolated Claude subscription instance.
The installing agent MUST resolve the Domo home once before generation, defaulting
to `$HOME/.domo` for user installs. A dev rehearsal MAY choose a different
absolute home before generation; once chosen, generated runtime files MUST embed
that literal path and MUST NOT read `DOMO_HOME` at runtime.

Hard dependencies:

- **macOS** - this slice targets Claude Code subscription auth on the user's Mac.
- **Claude Code CLI** - `claude` MUST be on `PATH`.
- **Claude subscription auth** - the user MUST be able to complete the
  browser-based `claude.ai` login flow.
- **`jq`** - generated verification helpers MUST use it for strict JSON checks.
- **A real terminal** - the login helper launches Claude Code's interactive TUI
  and must leave the terminal sane after it exits.

`ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN` MUST be unset for every
generated Claude launch path in this slice.

## Objects

- **Baked Domo home** - the absolute install home selected before generation.
  The default user-install path is `$HOME/.domo`; auth-dependent rehearsals use
  their stable baked path. This slice writes only under that home. The path MUST
  be byte-identical across auth-dependent rehearsals because Claude subscription
  credentials are Keychain-keyed to the exact `CLAUDE_CONFIG_DIR` path; copying
  `.credentials.json` or other config files to a different path does not carry a
  usable login.
- **Isolated Claude config dir** - `<HOME>/.claude`, exported as
  `CLAUDE_CONFIG_DIR` by every generated helper.
- **Domo workspace path** - `<HOME>/workspace`. The generated config pre-trusts
  this path so later slices can start the persistent daemon without a trust
  prompt.
- **Seeded Claude config** - `<HOME>/.claude/.claude.json` and
  `<HOME>/.claude/settings.json`, both chmod 600.
- **Claude-instance runtime dir** - `<HOME>/runtime/claude-instance`, containing
  generated helpers for `login`, `auth-status`, and `logout`.
- **Login helper** - a generated executable that runs `claude "/quit"` under the
  isolated config with metered keys unset, then drains delayed terminal input and
  runs `stty sane` when stdin is a TTY. The helper uses `claude "/quit"`, not
  `claude auth login`, because the auth subcommand can skip the normal TUI and
  browser first-run flow; the TUI path is what reliably seeds subscription auth
  in the isolated config.
- **Auth-status helper** - a generated executable that runs
  `claude auth status --json` under the isolated config and succeeds only for
  the four-field subscription-auth truth.
- **Logout helper** - a generated executable that runs `claude auth logout` under
  the isolated config. It is owned by this slice and consumed by the later
  `domo-runtime` reset action; installs and rehearsals MUST NOT call it unless
  explicitly testing reset/logout behavior.

## Actions

### Claude instance is generated

The installing agent MUST generate this slice into the baked Domo home. It MUST
NOT copy `ref/domo-login-piece.sh` or depend on any committed login script.

1. Resolve the baked home to an absolute path. Create:

   ```text
   <HOME>/.claude
   <HOME>/workspace
   <HOME>/runtime/claude-instance
   ```

2. Write `<HOME>/.claude/.claude.json` chmod 600. Preserve any existing valid
   JSON object, but ensure these fields are present:

   ```json
   {
     "hasCompletedOnboarding": true,
     "fullscreenUpsellSeenCount": 3,
     "projects": {
       "<HOME>/workspace": {
         "hasTrustDialogAccepted": true
       }
     }
   }
   ```

   If `fullscreenUpsellSeenCount` already exists and is greater than `3`, keep
   the greater value.

3. Write `<HOME>/.claude/settings.json` chmod 600. Preserve any existing valid
   JSON object, but ensure:

   ```json
   {
     "theme": "dark",
     "tui": "default"
   }
   ```

   If `theme` already exists, preserve it; `tui` MUST be `"default"`.

4. Generate the login helper under `<HOME>/runtime/claude-instance`. Its Claude
   invocation MUST be exactly:

   ```bash
   env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN \
     CLAUDE_CONFIG_DIR="<HOME>/.claude" \
     claude "/quit"
   ```

   The helper MUST print the baked home and isolated config path, but MUST NOT
   ask for, print, or copy Claude auth tokens. After Claude exits, when stdin is
   a TTY, the helper MUST drain delayed terminal input using noncanonical reads
   and then run `stty sane`.

5. Generate any prompt-confirmation helper needed for the Claude first-run TUI.
   It MUST match stable label anchors, not brittle full-screen text snapshots,
   because Claude can fragment prompts across terminal redraws. Required anchors
   are exactly:

   - If the prompt contains `Yes, try it`, send `2` to decline the fullscreen
     recommendation path.
   - If the prompt matches the monolith default-enter label regex
     `text style|Choose the text|Let.s get started|trust the files|trust this folder|project.*trust|Yes, I trust`,
     press Enter.

   The matcher SHOULD tolerate ANSI escapes, line wraps, and fragmented prompt
   text; it SHOULD strip control sequences before applying these regex anchors.
   It MUST NOT send `2` based on broad renderer words such as `fullscreen` or
   `Fullscreen`, because a fragmented prompt can expose those words before the
   stable `Yes, try it` option label appears.

6. Generate the auth-status helper. It MUST run:

   ```bash
   env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN \
     CLAUDE_CONFIG_DIR="<HOME>/.claude" \
     claude auth status --json
   ```

   It succeeds only when all four conditions hold:

   ```text
   rc == 0
   loggedIn == true
   authMethod == "claude.ai"
   apiProvider == "firstParty"
   ```

   It MUST treat missing, non-object, or unparsable JSON as not logged in.
   Its wait mode MUST poll every 2 seconds and MUST time out after 600 seconds.

7. Generate the logout helper. It MUST use the same isolated environment and
   MUST run `claude auth logout`. The helper is for later reset behavior, not
   for normal install verification.

8. Run the login helper if the auth-status helper does not already report the
   four-field subscription-auth truth. Surface the login command to the user and
   wait until the user completes browser login. Then poll auth-status every 2
   seconds until it succeeds or the 600-second install timeout expires.

If this slice's `## Verification` fails because a generated helper or config is
wrong, the installing agent MUST regenerate this slice exactly once and rerun
Verification. If the rerun still fails, stop the install, write terminal
`failure` with the reason to the repo-root `install-report.json`, and do not
attempt a third generation.

### Claude instance is logged out

This action clears only the isolated Claude subscription login for the baked
home. It is exposed for `domo-runtime` reset and MUST NOT be run during normal
install verification or against the stable auth'd rehearsal home unless the
reset/logout behavior itself is under test.

The generated logout helper MUST run:

```bash
env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN \
  CLAUDE_CONFIG_DIR="<HOME>/.claude" \
  claude auth logout
```

After logout, the caller MUST confirm `claude auth status --json` no longer
reports `loggedIn == true` before deleting any Domo home data.

## Verification

Verification runs against the just-generated real instance.

1. The auth-status helper MUST exit 0 and the raw `claude auth status --json`
   response under the isolated environment MUST satisfy the four-field login
   gate:

   ```text
   rc == 0
   loggedIn == true
   authMethod == "claude.ai"
   apiProvider == "firstParty"
   ```

2. Metered-key immunity MUST be shown on the generated launch paths. With
   `ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN` set to sentinel values in
   the parent environment, the generated login and auth-status helpers MUST
   still invoke Claude through `env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN`.

3. `<HOME>/.claude/.claude.json` MUST be chmod 600 and MUST contain:

   ```text
   hasCompletedOnboarding == true
   fullscreenUpsellSeenCount >= 3
   projects["<HOME>/workspace"].hasTrustDialogAccepted == true
   ```

4. `<HOME>/.claude/settings.json` MUST be chmod 600 and MUST contain:

   ```text
   tui == "default"
   theme is a non-empty string
   ```

5. No generated file in `<HOME>/runtime/claude-instance` MAY contain a runtime
   read of `DOMO_HOME`; all generated paths MUST be the baked absolute paths.

6. The logout helper MUST exist and be executable, but normal install
   verification MUST NOT run it.

7. The generated prompt-confirmation helper MUST contain the required stable
   anchors and no broad fullscreen fallback. This auth-independent check MUST
   pass:

   ```bash
   prompt="<HOME>/runtime/claude-instance/prompt-confirm.expect"
   grep -F 'Yes, try it' "$prompt"
   grep -F 'send "2\r"' "$prompt"
   grep -F 'text style|Choose the text|Let.s get started|trust the files|trust this folder|project.*trust|Yes, I trust' "$prompt"
   ! grep -F 'fullscreen|Fullscreen' "$prompt"
   ! grep -F 'Fullscreen|fullscreen' "$prompt"
   ```
