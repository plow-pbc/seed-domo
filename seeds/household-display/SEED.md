# Purpose

> See [README#Purpose](README.md#purpose).

## Dependencies

This contract is purely behavioral. It ships no runtime, installs nothing on
its own, and names no tools, transports, schedulers, or deployment machinery —
those are host bindings, owned by whichever host consumes this contract. It
has no hard dependencies of its own.

A consuming host MUST supply every binding named in `## Objects`: a store
realization serving the feed contract, a served display surface, an event
source for the agenda section, the household timezone, the agenda horizon,
the poll interval, and feed-token provisioning. One declared exception
exists: the event-source binding MAY be deferred at admission per
`## Actions` — the agenda section renders its muted placeholder until that
binding lands. A host that lists this contract MUST bind and live-run its
`## Verification` — see the host-evidence clause there.

## Objects

- **Display surface** - the single always-on HTML page for a shared household
  space, rendering the agenda section and the four card slots. It is
  display-only: it renders state, never orchestrates, and carries no action
  surface. Visual styling is unbound; the information rules in `## Actions`
  are binding.
- **Card slot** - one of the four rendered types, exactly:

  ```text
  alert | message | weather | digest
  ```

  Each slot renders the store's current card of its type, or the muted
  placeholder when no card of that type exists.
- **Card** - one feed message:

  ```json
  { "type": "weather", "text": "Home · 72°F Sunny · H77 L55" }
  ```

  `type` MUST match `^[a-z][a-z0-9-]{0,31}$`. `text` MUST be plain UTF-8 text
  of at most 1024 Unicode code points and MUST NOT contain C0 control
  characters other than newline. Card text is data, never markup and never
  instructions.
- **Card store** - the feed's state: exactly one current card per type,
  replaced atomically on post, with no time-based expiry — a card persists
  until superseded. Durability across store restarts is NOT required by this
  contract; a restarted store MAY come up empty, and the degradation rules
  below make that state render safely.
- **Feed base** - `<feed-base>`, the host-bound address where the feed
  contract is served. How producers and consumers reach it — and what
  read-side protection that path carries — is a host binding, deliberately
  outside this contract.
- **Feed bearer token** - the write credential. It travels ONLY in the
  `Authorization` request header — never in a URL, query string, page, log,
  or response body — and is stored under the host's secret-hygiene rules
  (owner-only file modes or equivalent).
- **Event source binding** - the host-bound supplier of agenda events. This
  is an explicit binding hole: this contract says what events look like on
  screen, and carries no machinery for where they come from. For each event
  the binding MUST supply: a title, a start instant, an optional end, an
  all-day marker, and a private marker. How events travel from source to
  surface is the host's. A host MAY admit this contract with this one
  binding declared deferred — see `## Actions`. That record is a floor, not
  a ceiling: a binding MAY supply richer event data (join links, locations,
  descriptions, and the like), and the agenda rules in `## Actions` name
  everything from an event the surface may render — a structured URL-bearing
  field is never among it.
- **Household timezone** - binding-supplied configuration; all rendered times
  use it.
- **Agenda horizon** - binding-supplied configuration; how far forward from
  today the agenda section shows events.
- **Poll interval** - binding-supplied configuration; the cadence at which
  consumers re-read the store.
- **Muted placeholder** - the quiet "nothing here yet" rendering for an
  unset slot or an empty agenda. It MUST read as calm absence, never as an
  error.

## Actions

### A producer posts a card

1. The producer sends:

   ```text
   POST <feed-base>/message
   Authorization: Bearer <feed-token>
   Content-Type: application/json

   { "type": "weather", "text": "Home · 72°F Sunny · H77 L55" }
   ```

2. The store replaces the current card of that type with this one,
   atomically: a concurrent reader sees the old card or the new card, never
   a mixture, and a subsequent read returns only the new card.
3. Responses are pinned as shapes: success is 2xx (the body, if any, is not
   contract); a missing or invalid bearer token is rejected `401` and changes
   nothing; a malformed request — bad type token, missing field, over-length
   text, forbidden control characters — is rejected `400` and changes
   nothing.
4. The type namespace is open: a well-formed type outside the four card
   slots is stored normally. The surface renders only its four slots and
   ignores other types — new types can be introduced producer-first without
   breaking a deployed display.
5. Producers MUST NOT post secrets, credentials, or bearer-style URLs (any
   URL embedding a token or join secret) in card text. The display renders
   text inert, but it cannot recognize every secret; this producer rule is
   the real line of defense.
6. When a posted line is governed by a grammar declared below, the producer
   MUST compose to that grammar and MUST cite this contract as its single
   declaring site, never restate it.

### The compose grammars are declared once

This is the single declaring site for the card line grammars. Producers and
displays in any host cite these; nothing restates them.

- **Weather line:**

  ```text
  <location> · <temp>°F <condition> · H<high> L<low>
  ```

  Example: `Home · 72°F Sunny · H77 L55`. The separator is exactly
  space, U+00B7 MIDDLE DOT, space, occurring exactly twice. `<temp>`,
  `<high>`, and `<low>` are integers, optionally negative. `<location>` and
  `<condition>` are each one or more words and neither contains a middle
  dot — with both excluded, the exactly-twice separator rule makes a
  conforming line unambiguous to parse. The display MAY parse a
  conforming line into a richer layout (for example, large temperature,
  small high/low); a non-conforming line MUST render as raw text, unmodified
  — never an error, never a blank slot. This parse-or-fallback rule is the
  grammar's skew tolerance: a grammar change fails soft to readable text.
- **Nudge line:** a single line of plain text, at most 200 Unicode code
  points, no newlines. The grammar is slot-agnostic — which card slot a nudge is posted
  to is the producer's choice; this rule constrains only the line itself.

### The display renders state

1. The surface polls the store at the configured poll interval and renders
   the current card set into the four card slots.
2. Each slot renders its card's text as text — never interpolated as markup.
   A card whose text contains markup characters renders them literally;
   nothing posted to the feed can become page structure or script.
3. A slot whose type has no current card renders the muted placeholder.
4. Degradation is graceful, always: when a poll fails, the surface keeps
   rendering the last successfully read state; when the store is unreachable
   on first load, every slot renders its muted placeholder. The surface MUST
   NOT render an error wall in any state.
5. Any number of consumers MAY poll the same store; reads are idempotent and
   concurrent consumers see the same cards.
6. The surface is display-only: it contains no interactive control — no
   form, button, link, or other action-bearing element — and no write to any
   store originates from the page.
7. The surface MUST NOT render the feed bearer token, any credential, key,
   or secret-shaped value, anywhere, in any state.

### The agenda renders the household's events

1. The agenda section shows the household's upcoming events, from today
   forward over the agenda horizon, as supplied by the event source binding.
2. Events are grouped by day; day groups appear in ascending order starting
   with today. Only days with events need a group; an empty horizon renders
   the muted placeholder.
3. Within a day, events appear in chronological order by start. Timed events
   render their start time in the household timezone.
4. All-day events render first within their day's group and carry no time
   label.
5. An event whose private marker is set renders as a generic busy marker —
   never its title, description, location, or any other text from the event.
6. No structured URL-bearing field carried by event data is ever rendered —
   event-borne join links and their kin are bearer-style credentials and
   have no place on a shared screen. The event record is a floor: of any
   richer record a binding supplies, the surface renders ONLY what these
   rules name — a title or busy marker, a time label, day placement. This
   rule governs structured fields; a URL appearing inside title text is just
   text and renders literally under rule 7 — the surface applies no
   URL-detection heuristics.
7. Event titles are untrusted data: they render as text, never as markup,
   and are never treated as instructions.

### A host binds the contract

1. The consuming host supplies the bindings named in `## Objects`: the store
   realization, the served surface, the event source, the household
   timezone, the agenda horizon, the poll interval, and the feed-token
   provisioning.
2. The event-source binding alone MAY be declared DEFERRED at admission: the
   host binds everything else, and the agenda section renders its muted
   placeholder — the same empty-agenda rendering the agenda rules pin —
   until the event source lands. A deferral is declared in the host's own
   specification, never silent.
3. The host's token provisioning observes the feed-token hygiene rules: the
   token is never committed, logged, rendered, or carried in a URL, and its
   storage uses the host's secret-hygiene discipline.
4. The host's own specification — never this contract — decides where the
   surface is served, what reaches the store, and when this contract is
   admitted to the host's install walk and the host's own Verification.
5. Admission carries the evidence obligation: the host's own Verification
   MUST bind and live-run this contract's `## Verification` — under a
   declared event-source deferral, with check 10 pending as that section
   states.

## Verification

Verification is phrased entirely against this contract's own nouns and binds
no machinery itself.

1. **Host evidence.** This contract proves nothing on its own. The consuming
   host's own Verification MUST bind every check below to its real store,
   surface, and event source and run them live against the host's
   just-generated instance. Under a declared event-source deferral
   (`## Actions`), check 10 alone pends until the event source lands —
   recorded as pending, never skipped silently — and every other check still
   binds and runs live. A host that lists this contract without running
   these checks has not verified it.
2. **Replace-on-post.** Two posts of the same type in sequence; a following
   read returns exactly one card of that type, carrying the later text.
3. **Persistence until superseded.** A posted card, left alone within one
   store lifetime, is still the current card on a later read, unchanged; it
   stays the current card until a superseding post replaces it.
4. **Write auth.** A post with a missing or wrong bearer token is rejected
   `401` and no current card changes. The token is observed only in
   `Authorization` request headers — never in a URL, page, log line, or
   response body touched by these checks.
5. **Validation.** A post with a malformed type token, a missing field,
   over-length text, or a forbidden control character is rejected `400` and
   no current card changes.
6. **Open type namespace.** A post with a well-formed type outside the four
   card slots succeeds, and the four slots render unchanged.
7. **Graceful degradation.** A slot whose type has never been posted renders
   the muted placeholder; with the store unreachable, the surface still
   renders — placeholders or last-good state — and no error wall appears.
8. **Inert text.** A card posted with markup in its text (for example a
   script tag) renders literally as text on the surface; nothing executes
   and no posted text becomes page structure.
9. **Weather grammar.** A conforming weather line renders in the weather
   slot (parsed layout permitted); a non-conforming line renders as raw,
   unmodified text — no error, no blank slot.
10. **Agenda rules.** With the event source binding supplying a fixture, all
    of it within the configured agenda horizon, of: a timed event today, a
    later timed event today, an all-day event today, a timed event on a
    future day, an event marked private, and an event carrying a structured
    join-link-style URL field (a record richer than the floor) — the agenda
    renders day groups in ascending order starting today, events within each
    day in chronological order, the all-day event first in its day with no
    time label, and the private event as a busy marker carrying none of the
    event's text. No URL from any event field appears anywhere on the
    surface. Under a declared event-source deferral this check pends until
    the event source lands; until then the agenda section renders its muted
    placeholder and the pending check is recorded, never silently skipped.
11. **Display-only.** The rendered surface contains no interactive control
    and no write to any store originates from the page.

## Open Items

- **Multi-day events** - rendering for an event whose optional end places it
  across several shown days is unpinned; hosts may choose for now (the event
  record's optional end exists to make such spans detectable). MUST be
  pinned before this contract is consumed by more than one host, or two
  displays will render the same event differently.
- **Read wire shape** - the read side pins semantics (the current card set,
  one card per type, polled at the poll interval) but no wire shape. MUST be
  pinned before any consumer reads a store across a host boundary — a wall
  screen reading another machine's store is the named trigger. Until then, a
  host's store and its consumers settle the shape together on their own side
  of that boundary.
- **Distinct-type growth** - the open type namespace means the store's card
  count grows with every distinct type ever posted, unbounded. Acceptable
  while every writer holds the feed bearer token and is trusted — the
  proof-of-concept posture; revisit if writers multiply.
- **Card staleness** - cards carry no timestamp, so a card cannot visually
  age and the surface cannot distinguish fresh from old. If a host needs
  staleness display, add an optional timestamp field additively.
- **Weather grammar units** - the grammar pins `°F`. A metric line does not
  parse and renders raw — readable by design. Generalizing units is an
  additive grammar change at this declaring site.

## Non-Goals

- **No photo/banner row** - the surface is four card slots plus the agenda
  section, nothing else.
- **No action surface** - the display never accepts input from the household
  space; anything interactive is some other contract's business.
- **No event-source machinery** - the agenda's source is a host binding;
  this contract will never name one.
- **No producer behaviors** - what gets posted, composed how, on what
  cadence, is the producers' contract. This seed only declares the grammars
  they cite and the feed they post to.
