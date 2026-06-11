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
- **Login helper** - a generated executable that runs `claude auth login` under
  the isolated config with metered keys unset. The installing agent runs the
  helper and captures the auth URL the subcommand emits (`Opening browser to
  sign in… / If the browser didn't open, visit: <url>`); the user completes the
  browser step and `claude auth login` auto-detects completion through its
  callback back-channel and writes the credential, so no code paste is needed
  in the normal case — the `Paste code here if prompted` line is a fallback
  only. The helper drains delayed terminal input and runs `stty sane` when
  stdin is a TTY, and MUST NOT ask for, print, or copy Claude auth tokens.
  `claude auth login` writes a FRESH `.claude.json` WITHOUT onboarding flags, so
  the onboarding seed is applied AFTER auth completes (the SEED-AFTER-LOGIN
  ordering pinned in `## Actions`); `/login` is retained only as the documented
  manual-recovery path (see `## Verification`), not the install mechanism.
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

2. Write `<HOME>/.claude/settings.json` chmod 600. `claude auth login` does not
   touch this file, so it is safe to write before auth. Preserve any existing
   valid JSON object, but ensure:

   ```json
   {
     "theme": "dark",
     "tui": "default"
   }
   ```

   If `theme` already exists, preserve it; `tui` MUST be `"default"`.

3. Generate the login helper under `<HOME>/runtime/claude-instance`. Its Claude
   invocation MUST be exactly:

   ```bash
   env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN \
     CLAUDE_CONFIG_DIR="<HOME>/.claude" \
     claude auth login
   ```

   The installing agent runs this helper and captures the auth URL the
   subcommand emits (`Opening browser to sign in… / If the browser didn't open,
   visit: <url>`). The user completes the browser step; `claude auth login`
   auto-detects completion through its callback back-channel and writes the
   credential, so no code paste is needed in the normal case — the
   `Paste code here if prompted` line is a fallback only. The helper MUST print
   the baked home and isolated config path, but MUST NOT ask for, print, or copy
   Claude auth tokens. After the subcommand exits, when stdin is a TTY, the
   helper MUST drain delayed terminal input using noncanonical reads and then
   run `stty sane`.

4. Generate any prompt-confirmation helper needed for the Claude first-run TUI.
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

5. Generate the auth-status helper. It MUST run:

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

6. Generate the logout helper. It MUST use the same isolated environment and
   MUST run `claude auth logout`. The helper is for later reset behavior, not
   for normal install verification.

7. Run the login helper if the auth-status helper does not already report the
   four-field subscription-auth truth. The installing agent runs the helper,
   captures the emitted auth URL, and surfaces it to the user — in the primary
   tier through the installer page's login watch section (the root SEED pushes
   the captured URL to the page); the terminal command is the no-page fallback.
   `claude auth login` auto-detects the browser completion and writes the
   credential independent of any TUI session, so the user need only finish the
   browser step. Then poll auth-status every 2 seconds until it succeeds or the
   600-second install timeout expires.

8. SEED-AFTER-LOGIN — only after the auth-status helper reports the four-field
   subscription-auth truth, write `<HOME>/.claude/.claude.json` chmod 600 with
   the onboarding seed. `claude auth login` writes a FRESH `.claude.json`
   WITHOUT onboarding flags (it carries only the `oauthAccount` plus runtime
   fields), so this seed MUST be applied AFTER auth completes; a seed written
   before login is clobbered by the login's own `.claude.json` write — both
   orders are proven in rehearsal, so the ordering is documented, not assumed.
   Preserve any existing valid JSON object (including the `oauthAccount` the
   login wrote), but ensure these fields are present:

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
   the greater value. On a re-install where auth is already satisfied, step 7
   runs no login and this seed still applies idempotently.

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

8. Manual-recovery path (documented, not the install mechanism): if
   `claude auth login` cannot complete for a user, `claude "/login"` run under
   the same isolated environment opens the in-TUI login-method selector
   (verified on Claude Code 2.1.173) and reaches the same subscription-OAuth
   flow. It is the fallback an operator may invoke by hand; the generated login
   helper uses `claude auth login` (Objects, step 3).
