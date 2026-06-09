# Group Plow chat — reference

How to stand up a **group** Plow chat (one agent line + N human members), as a
concrete pattern for an authoring agent. This is **reference, not a script to
ship**: it shows the request/response shapes drawn from the Plow OpenAPI
(`https://api.plow.co/openapi.json`) and the `seed-plow-chat` examples.

The **solo** shape is already what `ref/domo activate` does: activate with
`provision_chat: true` and Plow hands back a token plus a provisioned 1:1 chat in
one handshake. See `ref/domo` for that path. This doc covers the group shape,
where the chat is created explicitly and members verify individually.

Field names below are confirmed against the live `openapi.json` (Plow API
`0.1.0`). All `<...>` are placeholders — never paste a real token or code.

```
Base   https://api.plow.co        API root /v1
Auth   Authorization: Bearer <token>     # USER-WIDE; chmod-600 in state.json; never log/print/commit
WSS    wss://api.plow.co/v1/ws?ticket=<ticket>
```

> **Security.** The Bearer session token is a user-wide credential. It lives
> chmod-600 inside `state.json` and MUST NOT be logged, printed, or committed.
> `ANTHROPIC_API_KEY` stays unset (the Domo session uses subscription auth).
> The `VERIFY-XXXXXX` codes below are one-time secrets too — surface them to the
> user to text, don't persist or log them.

---

## 1. You already have a token + a line id

Group chat reuses the **same activation handshake** as the solo path; you just
don't ask it to provision a chat for you. After `POST /v1/auth/activate` →
(user texts the code) → `POST /v1/auth/activate/redeem`, the verified redeem
returns the user-wide `token`:

```jsonc
// 200 — ActivationRedeemVerified
{ "status": "verified", "token": "<token>", "chat": null }
```

The `line_id` (the agent's messaging line, `ln_...`) is surfaced two ways: the
activation create response carries `line_id`, and `GET /v1/lines` lists the pool.

```bash
curl -s https://api.plow.co/v1/lines \
  -H "Authorization: Bearer <token>"
```

```jsonc
// 200 — LineListResponse
{
  "object": "list",
  "data": [
    { "object": "line", "uid": "ln_...", "provider_type": "imessage",
      "provider_key": "+15555550101" }   // the number members text to verify
  ],
  "has_more": false,
  "url": "/v1/lines"
}
```

Provider is iMessage (with transparent SMS fallback for non-iOS recipients).
`provider_key` is the address members will text.

---

## 2. Create the group chat

`POST /v1/chats` with one `agent` participant (carries the `line_id`) and one or
more `member` participants. **Exactly one agent; at least one member.** Members
are identified by `display_name` only — their phone/Apple ID identity is NOT
supplied here; it is learned at verification when they text their code.

```bash
curl -s -X POST https://api.plow.co/v1/chats \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "participants": [
      { "type": "agent",  "line_id": "ln_..." },
      { "type": "member", "display_name": "Patrick" },
      { "type": "member", "display_name": "Sarah" }
    ]
  }'
```

`participants[]` is discriminated by `type`. The agent entry's only field is
`line_id` (pattern `^ln_...`); each member entry's only field is `display_name`
(1–255 chars).

---

## 3. The 201 response is a ChatResource

Creation returns **HTTP 201** with a `ChatResource`: the chat `uid` (`cht_...`),
a `status`, and `participants[]`. Each **member** participant carries a
one-time `verification_code` of the form `VERIFY-XXXXXX` plus
`verification_code_expires_at`.

> The `verification_code` is returned **only on creation** (and on resend, see
> §5). It is NOT re-fetchable from `GET /v1/chats/{uid}`. Capture it from this
> response and hand it to that member to text. The **agent** participant has no
> verification fields (it has no participant row — it's derived from the line).

```jsonc
// 201 — ChatResource
{
  "uid": "cht_...",
  "object": "chat",
  "status": "pending",                  // -> "active" once every member verifies
  "provider_key": "+15555550101",
  "failure_reason": null,
  "participants": [
    {
      "type": "agent",
      "line": { "object": "line", "uid": "ln_...",
                "provider_type": "imessage", "provider_key": "+15555550101" }
    },
    {
      "type": "member",
      "object": "chat_participant",
      "uid": "cp_...",
      "status": "pending_verification",          // "pending_verification" | "active"
      "display_name": "Patrick",
      "provider_type": "imessage",
      "provider_key": null,                       // filled in once verified
      "verification_code": "VERIFY-XXXXXX",       // one-time; not re-fetchable
      "verification_code_expires_at": "2026-06-01T12:00:00Z",
      "verified_at": null,
      "joined_at": null
    },
    {
      "type": "member",
      "object": "chat_participant",
      "uid": "cp_...",
      "status": "pending_verification",
      "display_name": "Sarah",
      "provider_type": "imessage",
      "provider_key": null,
      "verification_code": "VERIFY-XXXXXX",
      "verification_code_expires_at": "2026-06-01T12:00:00Z",
      "verified_at": null,
      "joined_at": null
    }
  ],
  "created_at": "2026-06-01T11:55:00Z"
}
```

---

## 4. Each member verifies by texting their own code

Hand each member **their own** `VERIFY-XXXXXX` and have them text it, from their
own phone, to the chat line's `provider_key` (the line number from §1/§3). That
inbound is how Plow learns and binds that member's messaging identity to their
`cp_...` participant.

Watch progress over the WSS. First mint a one-shot ticket scoped to the chat
(note the request field is `chat_id`), then connect:

```bash
curl -s -X POST https://api.plow.co/v1/ws/ticket \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{ "chat_id": "cht_..." }'
# -> { "object": "ws_ticket", "ticket": "<ticket>", "expires_at": "..." }

# wss://api.plow.co/v1/ws?ticket=<ticket>
```

As each member's text lands, a `participant_verified` frame fires (member
participants only — the agent has no verification state), and that member's
`status` flips `pending_verification` → `active`:

```jsonc
// frame — ParticipantVerifiedFrame
{
  "type": "participant_verified",
  "participant": {
    "type": "member",
    "uid": "cp_...",
    "display_name": "Patrick",
    "provider_key": "+15555550199",   // now bound — the member's own number
    "joined_at": "2026-06-01T11:58:00Z"
  }
}
```

When the last member verifies, the chat transitions to `active` and a
`chat_active` frame fires. The chat is usable once members are active.

---

## 5. Re-issue an expired or lost code

Codes expire (`verification_code_expires_at`). To re-issue one for a still-pending
member, `POST` the resend endpoint with the chat uid and that member's `cp_...`:

```bash
curl -s -X POST \
  https://api.plow.co/v1/chats/cht_.../invitations/cp_.../resend \
  -H "Authorization: Bearer <token>"
```

Returns the member participant (`ChatParticipantMember`) with a **fresh**
`verification_code` and new `verification_code_expires_at`:

```jsonc
// 200 — ChatParticipantMember
{
  "type": "member",
  "object": "chat_participant",
  "uid": "cp_...",
  "status": "pending_verification",
  "display_name": "Patrick",
  "provider_type": "imessage",
  "provider_key": null,
  "verification_code": "VERIFY-YYYYYY",     // new one-time code
  "verification_code_expires_at": "2026-06-01T13:00:00Z",
  "verified_at": null,
  "joined_at": null
}
```

(Resend `409`s if the chat is still pending in a way that doesn't accept it, and
`404`s for an unknown chat/member or a chat the session doesn't own — existence
isn't leaked to non-owners.)

---

## 6. Inbound messages are attributed per member

Once active, every message produces a `message_received` frame. For inbound
member messages, `message.sender` is a `MessageSenderMember` carrying `uid`,
`display_name`, and the member's `provider_key` — so the agent attributes each
message to a specific person:

```jsonc
// frame — MessageReceivedFrame
{
  "type": "message_received",
  "message": {
    "uid": "msg_...",
    "object": "message",
    "chat_uid": "cht_...",
    "direction": "inbound",
    "body": "what's on the calendar tomorrow?",
    "status": "received",
    "sender": {
      "type": "member",
      "uid": "cp_...",
      "display_name": "Sarah",
      "provider_key": "+15555550123"
    },
    "created_at": "2026-06-01T12:05:00Z"
  }
}
```

This `sender.display_name` is exactly what the `server.ts` change surfaces as the
per-sender user tag on the channel notification (replacing a hardcoded `"You"`),
so a group Domo always knows who is talking. Outbound echoes use a
`MessageSenderAgent` (`type: "agent"`, the chat's `line`, no member uid) and are
distinguished by `direction: "outbound"`.

---

### Notes for the authoring agent

- One agent participant per chat; the `line_id` is the agent's. Don't create two
  agent participants.
- Solo is just the N=1 case — but the activation shortcut
  (`provision_chat: true`) is the simpler path for solo and is what `ref/domo`
  uses. Reach for explicit `POST /v1/chats` when you need ≥2 members or want to
  control `display_name`s.
- Capture every `verification_code` from the create/resend response immediately;
  it's one-time and not re-fetchable. Surface it to the user to text; never log
  or commit it.
- The Bearer token from §1 is the single user-wide credential for all of the
  above. Keep it chmod-600 in `state.json`; never echo it into argv, logs, or
  commits.
