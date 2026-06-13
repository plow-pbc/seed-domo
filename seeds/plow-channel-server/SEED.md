# Purpose

> See [README#Purpose](../../README.md#purpose).

## Dependencies

This slice generates the Claude MCP channel server that bridges the persistent
Domo daemon to the already-activated Plow Chat conversation.

Hard dependencies:

- **Plow Chat contract SEED** - the installing agent MUST clone
  `https://github.com/plow-pbc/seed-plow-chat` from `origin/main` before
  generation, verify the clone contains baseline commit
  `fe24c9a53af1c9aeea5511cc6c1a797a2b770296` in its history, record the actual
  `git rev-parse HEAD`, and read that SEED's
  `## Objects` and `## Actions` as the only Plow HTTP and WebSocket API
  surface. This Domo SEED MUST NOT restate Plow endpoints, payload schemas,
  response schemas, or frame schemas. In a composed install the root has
  already cloned, audited, and recorded this contract; the root-carried clone
  path + recorded commit satisfy this requirement, and the slice reads from
  that clone rather than cloning again. Re-clone only when this slice is
  installed standalone, where standalone verifiability is the reason the
  per-slice clone path is kept.
- **Plow activation slice** - `<HOME>/.claude/plow-chat/state.json` MUST be
  written by `seeds/plow-activation/SEED.md` before live Verification can prove
  outbound sends, WebSocket connection, backfill, and inbound delivery.
- **Daily rhythms contract** - `seeds/daily-rhythms/SEED.md` declares the
  cadence table and behavior pipelines the generated scheduler module (steps
  15-19) bakes and binds. The table is baked as data with the household
  timezone substituted; behaviors not in the baked table do not fire.
- **Household display contract** - `seeds/household-display/SEED.md` is the
  single declaring site for the card feed and the weather-line grammar the
  deterministic `weather` behavior composes to — cited, never restated.
- **`bun`** - the generated MCP registration launches the channel server with
  Bun.

The installing agent MUST resolve the Domo home once before generation,
defaulting to `$HOME/.domo` for user installs. Generated runtime files MUST
embed that literal path and MUST NOT read `DOMO_HOME` or runtime state-path
environment variables.

The scheduler module additionally consumes three root-written install
artifacts: the baked **dashboard base URL** (`http://127.0.0.1:<port>`, a
non-secret install constant baked as a literal POST target), the **feed
token** at its pinned path `<HOME>/.claude/household-display/feed-token`
(read lazily at POST time — never baked into any file, never logged, never
in argv), and the **household location record**
`<HOME>/.claude/household-location.json` (`{label, lat, lon, geocoded_at}`,
non-secret, chmod 600, written once by the root; read lazily at boot and
re-checked while absent). All three follow the `state.json` lazy-read
pattern, so generation order never depends on any of them being present.

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
  channel notifications to Claude. The scheduler module changes none of this:
  it is an internal module, never a tool surface.
- **Last-fired record** - `<HOME>/.claude/plow-chat/last_fired.json`,
  chmod 600, single writer (the scheduler module):
  `{ "<behavior>": "<iso8601>" }`. Written after each fire — for `llm`
  behaviors "fired" means the synthetic notification was emitted (the module
  cannot and does not track session completion); for `deterministic`, after
  the delivery attempt completes, success or final failure — an hourly
  behavior retries naturally at its next tick rather than via its record. A
  stamp in the future relative to now (clock rollback, corrupted record) is
  clamped to now with a loud stderr line — a bad stamp must never silence a
  behavior indefinitely. The pinned path is consumed across the seam by the
  root union's mode-600 hygiene evidence and by the rehearsal drills that
  stage overdue or future stamps — which is why the path, not just the
  shape, is contract.
- **Scheduler state marker** -
  `<HOME>/.claude/plow-chat/scheduler-state`, a non-secret marker beside the
  connected marker recording the scheduler's `armed` or `suppressed` state,
  written at every transition so operator `status`/`doctor` can surface a
  silently-unarmed scheduler at a glance.

## Actions

### Plow channel server is generated

The installing agent MUST generate this slice into the baked Domo home. It MUST
NOT vendor a prewritten server or depend on any committed channel implementation
as the installed runtime.

1. Read the Plow contract SEED's `## Objects` and `## Actions` before writing
   any server code — in a composed install from the root-carried clone, or, when
   this slice is installed standalone, from a fresh `origin/main` clone of
   `https://github.com/plow-pbc/seed-plow-chat` in a scratch directory. Treat
   that SEED as the only source for Plow HTTP calls, WebSocket ticketing,
   backfill behavior, frame names, and message fields.
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
   `DOMO_HOME` or runtime state-path environment variables. Internal
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
         "provider_key": "<sender provider key when present>",
         "current_date": "<host-local YYYY-MM-DD at delivery>",
         "day_of_week": "<host-local weekday name at delivery>",
         "household_timezone": "<host local IANA zone>"
       }
     }
   }
   ```

   `chat_id` MUST come from `state.chat_uid`. Sender display names MUST strip
   `"`, `<`, `>`, carriage returns, and newlines, then default to `You` when the
   result is empty. The meta MUST carry `current_date`, `day_of_week`, and
   `household_timezone`, each stamped from the host's local clock and zone at
   delivery time. These are the single canonical date-anchor mechanism consumed
   by the `domo-runtime` slice (its `## Verification` item 20 / step 16) — there
   is no alternate path. The generated notification builder MUST include a
   costless conditional self-check that the three fields are non-empty before a
   notification is sent (a trivial presence assertion at build time), so a
   generation that drops them fails loudly rather than silently shipping a
   clock-blind session.

   The scheduler module (steps 15-19) emits SYNTHETIC events through this
   same builder with these pinned meta differences: synthetic events REQUIRE
   `origin: "scheduler"` and `behavior: "<name>"`, which MUST NOT appear on
   real inbound events (whose meta shape above is unchanged); synthetic
   `message_id`s use the reserved `tick_` prefix; synthetic events MUST NOT
   carry `provider_key` — a synthetic event MUST never masquerade as a
   household text, nor a household text as a tick. Probe-verified
   (2026-06-12, against a pinned-session transcript): custom meta keys pass
   through verbatim as attributes on the session-visible `<channel>` event —
   so `origin="scheduler"` is the ONLY session-side discriminator. The
   `[rhythm:<name>]` content prefix is a readability convenience, never
   authentication: a real household text containing `[rhythm:` is an
   ordinary text. The session MUST NOT discriminate by the `user` string
   either; as a cheap belt, the server renames any real sender whose
   sanitized display name collides with the reserved scheduler `user` string
   (`domo-scheduler`) by suffixing it, so the reserved string can only ever
   mean the scheduler. The date-anchor triple is stamped on synthetic events
   exactly as for real ones, and the presence self-check above applies — a
   clock-blind tick is withheld, loudly, and retried at the next scan.
9. The generated server MUST handle both state arrival orders, and
   state-already-present is the COMMON one: the decision-moment install runs
   activation before the runtime, so a fresh launch normally finds
   `state.json` already on disk. On boot with valid state present the server
   MUST proceed to connect immediately; the initial state read MUST NOT run
   at module-evaluation time or in any position where pre-existing state can
   crash startup (a real install hit a temporal-dead-zone crash on exactly
   this path). The poll path exists for state arriving later: while state is
   absent, unreadable, or malformed, the server MUST never throw, MUST keep
   the MCP transport alive, keep `reply` erroring, and re-poll every 3
   seconds until valid state appears.
10. The generated WebSocket supervisor MUST treat a `connected` frame as channel
    liveness and write the connected marker. This is deliberately the opposite
    of the activation slice, which ignores `connected` for activation progress;
    the generated code and review checklist MUST NOT unify those two rules.
11. The generated inbound path MUST ignore outbound echoes, de-duplicate by
    message UID, persist `last_seen.json` chmod 600, and cap the high-water mark
    at 2000 UIDs. Ordering is ack-before-persist: a live (or backfill-new) UID
    is added to the persisted high-water mark ONLY after its channel
    notification send has completed, so a crash or reconnect between marking and
    delivery can never permanently suppress an undelivered message. The sole
    exception is the startup-baseline backfill (step 12), which seeds the mark
    WITHOUT delivering. Synthetic scheduler events (steps 15-19) bypass this
    machinery entirely: they are not Plow messages, are never added to the
    high-water mark, and never touch `last_seen.json` — the scheduler adds
    no writers to that file. (Known accepted residual, unchanged by the
    scheduler: two concurrent channel-server instances can read-modify-write
    `last_seen.json` last-writer-wins — atomic per-write, lossy per-merge;
    the step-19 suppression keeps the transient second instance's scheduler
    dark, and no scheduler path writes the file.)
12. First backfill after a fresh server start MUST seed the high-water mark
    without delivering historical messages. On daemon restart, historical
    messages already in the chat MUST NOT be replayed to Claude; a fresh inbound
    message after restart MUST still be delivered.
13. The generated supervisor and scheduler MUST use these pinned timing
    values:

    ```text
    CONNECT_TIMEOUT_MS=30000
    IDLE_TIMEOUT_MS=90000
    INITIAL_BACKOFF_MS=1000
    MAX_BACKOFF_MS=30000
    BACKOFF_RESET_AFTER_MS=10000
    STATE_REPOLL_MS=3000
    LAST_SEEN_CAP=2000
    SCHEDULER_SCAN_MS=60000
    WEATHER_FETCH_TIMEOUT_MS=10000
    ```

14. Generated logging MUST go to stderr, MUST include status codes only for Plow
    failures, and MUST never include the Bearer token, Authorization header, or
    request/response bodies that could echo secrets. The same discipline
    covers the scheduler module: feed-POST and weather-fetch failures log
    status codes only, and neither the feed token nor card text is logged.

15. Generate the scheduler module INSIDE the channel server — it owns the
    only seam that can inject events into the pinned session (its stdout
    notification pipe), and a welcome consequence is that scheduler downtime
    IS daemon downtime, so the step-17 fire rule covers every gap with one
    mechanism. At generation time bake the `daily-rhythms` cadence table
    into the server as data, with the household timezone substituted (the
    host-local IANA zone resolved at install). The baked table is the
    complete rhythm set. The `weather` row stays baked regardless of
    location capture: its fires are gated lazily on the household location
    record (the contract's omit-OR-equivalently-suppress degraded mode), so
    a location that arrives later needs no regeneration. The tick engine
    evaluates each behavior's cron expression at minute granularity
    (`SCHEDULER_SCAN_MS`) in the household timezone. The module ARMS when
    the host's `notifications/initialized` arrives — never at the
    `initialize` exchange itself — and its FIRST evaluation runs one
    `SCHEDULER_SCAN_MS` after arming, never at the arming instant. Both
    halves are probe-verified loss modes (2026-06-12): the host registers
    channel routing milliseconds AFTER `initialized` (measured: registration
    16 ms after connect; a boot-instant synthetic fire lost the race by
    4 ms), and a notification emitted before registration is dropped
    silently with the stamp already consumed — the tick is lost until its
    next natural cron occurrence. One scan interval is the constant-free
    margin, and the uniform fire rule (step 17) makes the delayed first
    evaluation a pure shift: overdue ticks still fire exactly once, one
    interval later. The margin is empirical, not contractual — the host
    emits no protocol signal at registration, so a host that registered
    later than one interval would still drop a fire silently; the measured
    margin is about four orders of magnitude. The suppression decision
    (step 19) still keys off the `initialize` handshake's `clientInfo`,
    stashed until arming. The scheduler is an internal module, never a tool
    surface: the advertised capabilities stay step 5's verbatim, no new
    tool exists, and `tools/list` returns exactly `reply` (step 7).

16. On an `llm` behavior's fire the module calls the existing notification
    builder and emits a `notifications/claude/channel` event into the pinned
    session — the same delivery path as a real inbound, with the step-8
    synthetic meta pins. The content line is
    `[rhythm:<name>] Scheduled tick — run the <name> rhythm now per your
    workspace instructions.`; the `meta.user` is the reserved
    `domo-scheduler`; the `message_id` is `tick_<name>_<scheduled>` where
    `<scheduled>` is the SCHEDULED time of the tick being fired (never the
    fire time) — non-collision with Plow uids is not load-bearing, because
    synthetic events bypass the dedup machinery entirely (step 11). The tick
    event itself is never echoed outbound and never appears in the chat;
    only what the session then sends through `reply` (or posts via the
    runtime slice's card helper) is user-visible.

17. Generate ONE uniform fire rule; catch-up is a corollary, not a separate
    boot-only pass. At EVERY evaluation moment — the first scan, one
    `SCHEDULER_SCAN_MS` after arming (step 15), then each subsequent scan —
    a behavior fires once iff at least one cron tick exists strictly after
    its last-fired stamp and at-or-before now (in the household timezone).
    Firing stamps last-fired = now, so the boot evaluation and that same
    minute's scan can never double-fire. Missed-tick catch-up follows: a 4pm
    boot after a missed 7am sees one overdue tick and fires one late recap,
    never nine weather posts; a catch-up fire's `tick_` id carries the
    SCHEDULED time of the latest overdue tick. An implementation MAY bound
    how far back it searches for an overdue tick, but the bounded window
    MUST exceed the longest cron period in the baked table — a shorter
    bound could silently skip a behavior's only overdue tick. WSS reconnect triggers
    nothing — it is Plow-side liveness; the scheduler's clock never stopped,
    only process death stops it — and "on start" is simply the first
    evaluation moment of the rule. Gating, uniformly: `llm` fires are
    additionally gated on valid `state.json` present, and `deterministic`
    fires on the household location record where the behavior needs one. A
    gated behavior does NOT stamp last-fired while gated — so state or
    location arriving later (via the existing 3-second re-poll, or a
    late-settled install answer) fires it on the next minute scan, once. Two
    timing pins: a tick landing in the arming minute needs no special owner
    — whichever evaluation sees it first fires and stamps, and the stamp
    makes the other a no-op; across a DST fold the repeated local hour fires
    once — the predicate compares absolute instants, not wall-clock
    recurrences. First-record semantics (no stamp on disk at boot): a
    missing stamp is initialized to now for `llm` behaviors (an install
    completing at 9pm must not text the family a "morning" recap) and to one
    tick in the past for `deterministic` behaviors, so each fires on the
    first scan once — free, idempotent, and it hands the install's union
    Verification a live tick within one scan interval of install time.

18. On a `deterministic` tick the module runs entirely in-process — no
    session traffic, no notification, no `reply`, no LLM in any host. For
    the `weather` behavior: read the household location record lazily; fetch
    current conditions plus today's high/low from Open-Meteo's keyless API
    (no account, no API key, no secret surface; bounded by
    `WEATHER_FETCH_TIMEOUT_MS`); compose exactly the weather-line grammar
    `household-display` declares (cited, never restated), rendering the
    record's `label` — the user's own entered text — as the grammar's
    location; and `POST <feed-base>/message` as type `weather` with the
    bearer token read lazily from the pinned token path. Fetched strings
    (condition names, location label) are sanitized before composing:
    control characters stripped and the grammar's reserved middle-dot
    separator removed, so third-party data never forges grammar structure
    (the display escapes on render; this keeps the line parseable). A failed
    fetch or POST delivers nothing — the previous card persists per the
    feed's replace-per-type semantics (cited) — and the failure is logged to
    stderr with status code only (step 14).

19. `send-ready` transiently spawns a second channel-server instance whose
    supervisor also connects; its scheduler MUST NOT fire. The pinned
    mechanism is deliberately inverted from the obvious one: the scheduler
    ARMS BY DEFAULT and is suppressed when the MCP `initialize` handshake's
    `clientInfo` identifies the generated `send-ready` client (its
    `clientInfo.name` is exactly `send-ready` — code this install generates
    and controls), NEVER by positive-matching unpinned Claude client
    strings, which can change underneath and would silently kill every
    rhythm. Both transitions are loud: arming and suppression each log one
    stderr line, and the armed/suppressed state is written to the non-secret
    scheduler state marker beside the connected marker so operator
    `status`/`doctor` surface it. The marker path is shared and
    last-writer-wins, so an ARMED scheduler MUST re-assert its marker at
    every evaluation — otherwise a transient instance's `suppressed` write
    misrepresents a live daemon (live-found at the composed rehearsal: the
    send-ready transient clobbered the daemon's `armed` marker);
    re-assertion bounds the misrepresentation to one scan interval. A
    silently-dead scheduler is the failure
    mode this step exists to prevent. One residual, recorded beside the
    step-11 note: a future non-`send-ready` direct client would arm a second
    scheduler — and with it a second `last_fired.json` writer; no such
    spawner exists in v1 (`send-ready` is the only generated direct client),
    and any future one must identify itself for suppression the same way.

If this slice's `## Verification` fails because a generated server is wrong,
the installing agent MUST regenerate this slice exactly once and rerun
Verification. If the rerun still fails, stop the install, write terminal
`failure` with the reason to the repo-root `install-report.json`, and do not
attempt a third generation. There is no vendored fallback unless a recorded
head-chef escalation decision explicitly authorizes it.

## Verification

Verification runs against the just-generated real instance. It is live operator
evidence only, plus the thin self-checks needed to decide whether the
regenerate-once policy has passed or failed. Because this slice installs before
`plow-activation` and `domo-runtime`, items that need `state.json` or the
consuming operator path are collected once those slices are installed, and the
root union Verification re-asserts them.

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

3. Present-state boot path: launched with valid `state.json` already on disk
   — the common decision-moment ordering — the just-started server
   initializes cleanly and proceeds directly to connect, with no crash and no
   3-second re-poll detour before the first connection attempt. Like items
   2 and 4 this is collected once activation state exists, and the root union
   re-asserts it.

4. Send through the real `reply` path and confirm the message lands in the Plow
   chat with `status` equal to `sent`. Evidence MUST record the non-secret chat
   UID plus the sent message UID/body/status, and MUST NOT record the token.

5. Token hygiene MUST be clean. The Plow token value from `state.json` MUST NOT
   appear in argv, generated logs, committed files, dashboard text, or the
   install evidence. The probes are presence-only — each emits only its fixed
   pass/fail status, never the matching line — and the token never enters any
   probe's own argv: the process table is matched in-shell, and the file/git
   greps read their needle from a here-string on fd 3 rather than a command
   argument, so nothing leaks the token into `ps`:

   ```bash
   token="$(jq -r '.token' "<HOME>/.claude/plow-chat/state.json")"
   test -n "$token"
   case "$(ps -axww -o args=)" in *"$token"*) false ;; esac
   ! grep -Rqf /dev/fd/3 "<HOME>/.claude/run" 3<<<"$token" 2>/dev/null
   ! git grep -qf /dev/fd/3 3<<<"$token"
   ```

6. Scheduler surface unchanged: with the scheduler module generated,
   `tools/list` returns EXACTLY `reply`, and the advertised capabilities are
   step 5's verbatim.

7. Deterministic tick, no LLM: with the location record present, a `weather`
   fire fetches real conditions and POSTs a grammar-conforming card to the
   baked feed with ZERO session traffic — no `notifications/claude/channel`
   is emitted for it, asserted from the server's emitted JSON-RPC. While the
   location record is absent the behavior is suppressed — no fire, no error,
   no stamp — and a record arriving later fires it once on a following scan.

8. llm tick shape: an (overdue-drill) `morning-recap` fire emits exactly one
   notification carrying `origin:"scheduler"`, `behavior:"morning-recap"`, a
   `tick_`-prefixed `message_id` stamped with the SCHEDULED time of the
   latest overdue tick, the reserved `user`, the date-anchor triple, and no
   `provider_key` — asserted from the emitted JSON-RPC. Additionally, the
   transcript assertion: the `<channel>` event in a PINNED-SESSION
   TRANSCRIPT carries `origin="scheduler"` (the probe-verified passthrough,
   step 8) — asserted against the transcript, never the server log alone;
   the established stable-home rehearsal pattern serves this auth-dependent
   leg.

9. Catch-up fires once: with a last-fired stamp two or more ticks in the
   past, one boot fires the overdue behavior exactly once.

10. Zero-delivery honesty: a deterministic fire whose fetch or POST fails
    delivers nothing — no card change; the previous card persists — and
    logs status code only. `last_seen.json` is never touched by any
    synthetic event or scheduler path (high-water mark byte-identical
    across an llm fire).

11. Suppression: an `initialize` whose `clientInfo` names `send-ready`
    suppresses the scheduler with a loud stderr line and a `suppressed`
    scheduler state marker; a normal client arms it loudly with an `armed`
    marker; while suppressed, overdue stamps fire nothing.

12. Last-fired hygiene: `last_fired.json` is chmod 600, single-writer, and a
    future stamp is clamped to now with a loud stderr line at the next
    evaluation.
