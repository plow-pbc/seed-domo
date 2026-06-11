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
- **Login helper** - a generated executable that runs `claude "/login"` under
  the isolated config with metered keys unset, then drains delayed terminal
  input and runs `stty sane` when stdin is a TTY. The helper uses
  `claude "/login"` (the in-TUI login-method selector), not a bare
  `claude "/quit"` launch and not `claude auth login`: the `auth login`
  subcommand can skip the browser first-run flow, and a bare launch no longer
  surfaces any login wall because this slice pre-seeds
  `hasCompletedOnboarding: true` (which suppresses the onboarding login step).
  `/login` reliably opens the subscription-OAuth path regardless of onboarding
  state. The helper MUST NOT ask for, print, or copy Claude auth tokens.
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
NOT copy or depend on any committed login script.

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
     claude "/login"
   ```

   This opens the in-TUI login-method selector so the user can choose "Claude
   account with subscription" and complete the browser login. The helper MUST
   print the baked home and isolated config path, but MUST NOT ask for, print,
   or copy Claude auth tokens. After Claude exits, when stdin is a TTY, the
   helper MUST drain delayed terminal input using noncanonical reads and then
   run `stty sane`.

5. Generate any prompt-confirmation helper needed for the Claude first-run TUI.
   It MUST match stable label anchors, not brittle full-screen text snapshots,
   because Claude can fragment prompts across terminal redraws. Required anchors
   are exactly:

   - If the prompt contains `Yes, try it`, send `2` to decline the fullscreen
     recommendation path.
   - If the prompt matches the monolith default-enter label regex
     `text style|Choose the text|Let.s get started|trust the files|trust this folder|project.*trust|Yes, I trust`,
     press Enter.

   The matcher MUST tolerate ANSI escapes, line wraps, and fragmented prompt
   text: it MUST strip control sequences before applying these anchors, and it
   MUST match whitespace-insensitively by removing all whitespace from both the
   stripped output and the anchor patterns before comparing. The Claude TUI
   renders inter-word spacing with cursor-positioning escapes, so stripped
   output can legitimately read `Yes,tryit`; an anchor that requires literal
   inter-word spaces can never match. It MUST NOT send `2` based on broad
   renderer words such as `fullscreen` or `Fullscreen`, because a fragmented
   prompt can expose those words before the stable `Yes, try it` option label
   appears.

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
   four-field subscription-auth truth. The helper opens the in-TUI login-method
   selector; surface the command to the user and instruct them to choose
   "Claude account with subscription" and complete the browser login. Auth
   completes when the browser OAuth callback writes the Keychain credential
   (keyed to this `CLAUDE_CONFIG_DIR`), independent of the TUI session, so the
   user may close the TUI once logged in. Then poll auth-status every 2 seconds
   until it succeeds or the 600-second install timeout expires.

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

Verification runs against the just-generated real instance. It is live operator
evidence plus the thin self-checks needed to decide whether this slice passes.

1. The generated helpers exist, are executable, and are under the baked home:

   ```bash
   test -x "<HOME>/runtime/claude-instance/login"
   test -x "<HOME>/runtime/claude-instance/auth-status"
   test -x "<HOME>/runtime/claude-instance/logout"
   ```

2. The auth-status helper exits 0, and the raw `claude auth status --json`
   response under the isolated config satisfies:

   ```text
   rc == 0
   loggedIn == true
   authMethod == "claude.ai"
   apiProvider == "firstParty"
   ```

3. Generated Claude launch paths unset `ANTHROPIC_API_KEY` and
   `CLAUDE_CODE_OAUTH_TOKEN`; no generated helper depends on ambient metered keys
   or OAuth tokens.

4. `<HOME>/.claude/.claude.json` is chmod 600 and contains:

   ```text
   hasCompletedOnboarding == true
   fullscreenUpsellSeenCount >= 3
   projects["<HOME>/workspace"].hasTrustDialogAccepted == true
   ```

5. `<HOME>/.claude/settings.json` is chmod 600 and contains:

   ```text
   tui == "default"
   theme is a non-empty string
   ```

6. Generated files in `<HOME>/runtime/claude-instance` contain baked absolute
   paths and do not read `DOMO_HOME` at runtime.

7. The logout helper exists for reset delegation, but normal install
   verification does not run it.
