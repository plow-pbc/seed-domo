#!/usr/bin/env bun
/**
 * Plow Chat channel for Claude Code / Domo.
 *
 * Claude channel MCP server backed by a Plow Chat WebSocket client + REST
 * sender. There is NO listening server here.
 *
 * Channel contract:
 *   - capabilities: { tools: {}, experimental: { 'claude/channel': {} } }
 *   - instructions string telling Claude to reply via the `reply` tool and that
 *     inbound arrives as <channel source="plow-chat" ...> events.
 *   - INBOUND: mcp.notification({ method: 'notifications/claude/channel',
 *       params: { content, meta: { chat_id, message_id, user, ts } } })
 *   - OUTBOUND: standard MCP `reply` tool via ListTools/CallTool.
 *
 * Plow Chat API (see /tmp/seed-plow-chat/SEED.md):
 *   Base    https://api.plow.co ; API root /v1
 *   WSS     wss://api.plow.co/v1/ws?ticket=<ticket>
 *   Auth    Authorization: Bearer <token>  (USER-WIDE credential, never logged)
 *   Ticket  POST /v1/ws/ticket            {chat_id:<chat_uid>}      -> {ticket}
 *   Send    POST /v1/chats/{uid}/messages {body:"..."}              -> {uid,status}
 *   Backfill GET /v1/chats/{uid}/messages                          -> [..messages..]
 *
 * Secrets come from a chmod-600 state file whose path is in PLOW_CHAT_STATE
 * path and NEVER logs the token. If state is missing/unparseable, the server
 * still starts the stdio transport (so `claude --channels` loads cleanly) but
 * stays unconnected and `reply` returns isError until state appears. It MUST NOT
 * crash the stdio transport.
 */

import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
} from '@modelcontextprotocol/sdk/types.js'
import { readFileSync, writeFileSync, mkdirSync, rmSync } from 'fs'
import { dirname, join } from 'path'

// ---------------------------------------------------------------------------
// State file: { base_url, token, chat_uid }. Read lazily so a state file
// written AFTER launch (e.g. `./domo activate` while the session is up) can be
// picked up without restart (best-effort nicety).
// ---------------------------------------------------------------------------

type PlowState = { base_url: string; token: string; chat_uid: string }

const STATE_PATH = process.env.PLOW_CHAT_STATE ?? ''

// last-seen high-water mark: a small file beside state.json holding the uids we
// have ALREADY forwarded to Claude. Persisted so a fresh `./domo start` (after a
// stop / daemon restart) does not re-flood Claude with the entire prior chat
// history on the initial backfill. See finding #6. chmod 600 (same dir as the
// secret state). The Plow messages endpoint exposes no documented cursor param
// (no ?after / ?since / ?limit in the SEED), so we de-dupe client-side against
// this persisted set rather than server-side paging. Document once the live API
// is reachable: if a cursor param exists, prefer it (runtime-unverified).
const LAST_SEEN_PATH = STATE_PATH
  ? join(dirname(STATE_PATH), 'last_seen.json')
  : ''

// Non-secret readiness marker used by ref/domo-ready-piece.sh. Claude Code does
// not reliably forward this MCP child server's stderr to the daemon log, so the
// parent readiness probe must observe a file written by this process after a
// confirmed Plow WSS frame.
const CONNECTED_MARKER_PATH = process.env.PLOW_CHAT_CONNECTED_MARKER !== undefined
  ? process.env.PLOW_CHAT_CONNECTED_MARKER
  : (STATE_PATH ? join(dirname(STATE_PATH), 'connected') : '')

/** Read + validate the state file. Returns null (never throws) if not ready. */
function readState(): PlowState | null {
  if (!STATE_PATH) return null
  let raw: string
  try {
    raw = readFileSync(STATE_PATH, 'utf-8')
  } catch {
    return null
  }
  let parsed: any
  try {
    parsed = JSON.parse(raw)
  } catch {
    return null
  }
  const base_url = String(parsed?.base_url ?? '').replace(/\/$/, '')
  const token = String(parsed?.token ?? '')
  const chat_uid = String(parsed?.chat_uid ?? '')
  if (!base_url || !token || !chat_uid) return null
  return { base_url, token, chat_uid }
}

/** wss/ws origin derived from the state's base_url. */
function wsBase(base_url: string): string {
  return base_url.replace(/^http/, 'ws')
}

// ---------------------------------------------------------------------------
// MCP server — capability marker + channel instructions.
// ---------------------------------------------------------------------------

const mcp = new Server(
  { name: 'plow-chat', version: '0.1.0' },
  {
    capabilities: { tools: {}, experimental: { 'claude/channel': {} } },
    instructions:
      `The person you are talking to reads their messages over Plow Chat (texting), not this session. Anything you want them to see MUST go through the reply tool — your transcript output never reaches them.\n\n` +
      `Inbound messages arrive as <channel source="plow-chat" chat_id="..." message_id="..."> events; the meta also carries the sender's provider_key (their phone number) so you can recognize who is texting. Reply with the reply tool, which sends a text message back to that chat. Keep replies concise and SMS-appropriate.`,
  },
)

mcp.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'reply',
      description:
        'Send a text message to the Plow Chat conversation (delivered to the user as a text). Returns an error if the chat is not yet active (run ./domo activate).',
      inputSchema: {
        type: 'object',
        properties: {
          text: { type: 'string', description: 'Message body to send.' },
        },
        required: ['text'],
      },
    },
  ],
}))

mcp.setRequestHandler(CallToolRequestSchema, async req => {
  const args = (req.params.arguments ?? {}) as Record<string, unknown>
  try {
    switch (req.params.name) {
      case 'reply': {
        const text = String(args.text ?? '')
        if (!text.trim()) {
          return { content: [{ type: 'text', text: 'reply: empty text' }], isError: true }
        }
        // Re-read state on each send so a late activation is picked up.
        const state = readState()
        if (!state) {
          return {
            content: [{ type: 'text', text: `reply: plow-chat state not ready at ${STATE_PATH || '(PLOW_CHAT_STATE unset)'}; run ./domo activate` }],
            isError: true,
          }
        }
        // OUTBOUND: POST /v1/chats/{chat_uid}/messages {body}
        const res = await fetch(`${state.base_url}/v1/chats/${state.chat_uid}/messages`, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            Authorization: `Bearer ${state.token}`,
          },
          body: JSON.stringify({ body: text }),
        })
        if (res.status === 409) {
          // 409 chat_not_ready: chat not active yet. Surface clearly; do NOT crash.
          return {
            content: [{ type: 'text', text: 'reply: chat_not_ready (409) — the Plow chat is not active yet; the user must finish verification. Try again once the chat is active.' }],
            isError: true,
          }
        }
        if (!res.ok) {
          // Log status code only — never the token or body that might echo it.
          return {
            content: [{ type: 'text', text: `reply: send failed (HTTP ${res.status})` }],
            isError: true,
          }
        }
        let out: any = {}
        try { out = await res.json() } catch {}
        return { content: [{ type: 'text', text: `sent (${out?.uid ?? 'ok'}${out?.status ? `, ${out.status}` : ''})` }] }
      }
      default:
        return { content: [{ type: 'text', text: `unknown: ${req.params.name}` }], isError: true }
    }
  } catch (err) {
    return {
      content: [{ type: 'text', text: `${req.params.name}: ${err instanceof Error ? err.message : String(err)}` }],
      isError: true,
    }
  }
})

await mcp.connect(new StdioServerTransport())

// ---------------------------------------------------------------------------
// INBOUND: deliver a channel notification to Claude.
// ---------------------------------------------------------------------------

function deliver(content: string, meta: { chat_id: string; message_id: string; user: string; ts: string; provider_key?: string }): void {
  void mcp.notification({
    method: 'notifications/claude/channel',
    params: { content, meta },
  })
}

// ---------------------------------------------------------------------------
// INBOUND loop: mint ticket -> connect WSS -> handle frames -> reconnect.
//
// De-dup marker so backfill (GET messages) after a reconnect does not re-deliver
// messages we already forwarded.
// ---------------------------------------------------------------------------

const seenMessageUids = new Set<string>()
let chatActive = false // set true on 'connected'/'chat_active'; gates nothing on inbound but tracked for logging

// On the very first backfill of a process, we do NOT deliver pre-existing
// history — we only mark it seen (baseline). Only messages that arrive AFTER
// launch (live frames, or genuinely new rows on a later backfill) are forwarded.
// This flag flips false after the first backfill completes. See finding #6.
let firstBackfill = true

/** Load the persisted last-seen uids into seenMessageUids at startup. */
function loadLastSeen(): void {
  if (!LAST_SEEN_PATH) return
  try {
    const raw = readFileSync(LAST_SEEN_PATH, 'utf-8')
    const arr = JSON.parse(raw)
    if (Array.isArray(arr)) {
      for (const u of arr) if (u) seenMessageUids.add(String(u))
      // We have a prior baseline on disk, so this is NOT a first-ever start:
      // genuinely new messages SHOULD be delivered immediately.
      if (seenMessageUids.size > 0) firstBackfill = false
    }
  } catch {
    // No prior marker (or unreadable) -> first-ever start; baseline on first backfill.
  }
}

/** Persist the current seen set (best-effort, chmod 600). Caps size to avoid unbounded growth. */
function saveLastSeen(): void {
  if (!LAST_SEEN_PATH) return
  try {
    mkdirSync(dirname(LAST_SEEN_PATH), { recursive: true })
    // Keep only the most recent ~2000 uids to bound the file.
    const arr = Array.from(seenMessageUids).slice(-2000)
    writeFileSync(LAST_SEEN_PATH, JSON.stringify(arr) + '\n', { mode: 0o600 })
  } catch {
    // Best-effort; loss only risks a one-time re-deliver after a crash.
  }
}

function logErr(line: string): void {
  // stderr only; never include the token.
  process.stderr.write(`plow-chat: ${line}\n`)
}

function writeConnectedMarker(state: PlowState, event: string): void {
  if (!CONNECTED_MARKER_PATH) return
  try {
    mkdirSync(dirname(CONNECTED_MARKER_PATH), { recursive: true })
    writeFileSync(
      CONNECTED_MARKER_PATH,
      JSON.stringify({
        connected: true,
        event,
        pid: process.pid,
        chat_uid: state.chat_uid,
        at: new Date().toISOString(),
      }) + '\n',
      { mode: 0o600 },
    )
  } catch {
    // Best-effort marker; the channel itself should stay alive if the marker
    // cannot be written.
  }
}

function clearConnectedMarker(): void {
  if (!CONNECTED_MARKER_PATH) return
  try {
    const raw = readFileSync(CONNECTED_MARKER_PATH, 'utf-8')
    const marker = JSON.parse(raw)
    if (Number(marker?.pid) !== process.pid) return
    rmSync(CONNECTED_MARKER_PATH, { force: true })
  } catch {
    // Best-effort marker cleanup.
  }
}

/** POST /v1/ws/ticket {chat_id} -> ticket string. Throws on failure. */
async function mintTicket(state: PlowState): Promise<string> {
  const res = await fetch(`${state.base_url}/v1/ws/ticket`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${state.token}`,
    },
    body: JSON.stringify({ chat_id: state.chat_uid }),
  })
  if (!res.ok) throw new Error(`ws/ticket HTTP ${res.status}`)
  const data: any = await res.json()
  const ticket = data?.ticket
  if (!ticket) throw new Error('ws/ticket: no ticket in response')
  return String(ticket)
}

/**
 * GET /v1/chats/{chat_uid}/messages — backfill after a disconnect. De-dupes by
 * message.uid against seenMessageUids and ignores outbound echoes.
 */
async function backfill(state: PlowState): Promise<void> {
  let res: Response
  try {
    res = await fetch(`${state.base_url}/v1/chats/${state.chat_uid}/messages`, {
      headers: { Authorization: `Bearer ${state.token}` },
    })
  } catch (err) {
    logErr(`backfill fetch error: ${err instanceof Error ? err.message : String(err)}`)
    return
  }
  if (!res.ok) {
    logErr(`backfill HTTP ${res.status}`)
    return
  }
  let body: any
  try { body = await res.json() } catch { return }
  // The endpoint returns the Plow list envelope { object:"list", data:[...] };
  // also tolerate a bare array or a { messages:[...] } shape.
  const messages: any[] = Array.isArray(body) ? body : (body?.data ?? body?.messages ?? [])

  // First-ever backfill (no prior on-disk marker): seed the baseline WITHOUT
  // delivering, so a long-lived chat's history is not replayed to Claude as if
  // newly received. Subsequent backfills (and every live frame) DO deliver.
  const deliverNew = !firstBackfill
  for (const m of messages) handleInboundMessage(m, state, deliverNew)
  if (firstBackfill) {
    firstBackfill = false
    logErr(`backfill: established baseline of ${seenMessageUids.size} prior message(s) (not delivered)`)
  }
  saveLastSeen()
}

/**
 * Common path for a Plow `message` object (from a message_received frame or from
 * backfill). Ignores outbound echoes, de-dupes by uid, and delivers inbound.
 *
 * @param deliver_ when false (first-ever backfill baseline), the message is only
 *   marked seen, not forwarded to Claude. Live frames always pass true.
 */
function handleInboundMessage(message: any, state: PlowState | null, deliver_ = true): void {
  if (!message) return
  // IGNORE outbound echoes of our own sends.
  if (message.direction === 'outbound') return
  const uid = String(message.uid ?? '')
  if (!uid) return
  if (seenMessageUids.has(uid)) return
  seenMessageUids.add(uid)
  if (!deliver_) return // baseline: mark seen, do not forward (finding #6)
  const sender = message.sender ?? {}
  // chat_id: the SEED message object does NOT document a chat field on the
  // message, so source it from the authoritative state.chat_uid (always present)
  // rather than an undocumented message.chat_uid/chat_id (findings #8, #10).
  const chatId = String(message.chat_uid ?? message.chat_id ?? state?.chat_uid ?? '')
  // ts: prefer the message's own timestamp if Plow carries one; the SEED does not
  // document a field name, so try common spellings before falling back to receipt
  // time (finding #11; field name runtime-unverified).
  const ts = String(message.created_at ?? message.created ?? message.ts ?? new Date().toISOString())
  const providerKey = String(sender.provider_key ?? '')
  // Sender attribution: tag the channel notification with the inbound sender's
  // display name when present so a group chat surfaces WHO is talking; fall back
  // to "You" only when absent. Strip `"` `<` `>` and newlines so a name like
  // `Al "ace" <King>` can never break out of the attribute or the tag when
  // Claude renders this meta as a <channel ... user="..."> element — renderer-
  // agnostic, no attribute- or tag-injection regardless of how it's quoted.
  const displayName = String(sender.display_name ?? '').replace(/["<>\r\n]/g, '').trim()
  const user = displayName || 'You'
  deliver(String(message.body ?? ''), {
    chat_id: chatId,
    message_id: uid,
    user,
    ts,
    // provider_key (the underlying texting identity / phone number) so Claude can
    // distinguish or whitelist by sender (finding #8).
    ...(providerKey ? { provider_key: providerKey } : {}),
  })
  saveLastSeen()
}

/**
 * One connect attempt. Mints a fresh ticket, opens the WSS, wires frame
 * handlers, and resolves when the socket closes (so the caller can reconnect).
 */
function connectOnce(state: PlowState): Promise<void> {
  return new Promise<void>(async resolve => {
    let ticket: string
    try {
      ticket = await mintTicket(state)
    } catch (err) {
      logErr(`mint ticket failed: ${err instanceof Error ? err.message : String(err)}`)
      resolve()
      return
    }

    const url = `${wsBase(state.base_url)}/v1/ws?ticket=${encodeURIComponent(ticket)}`
    let ws: WebSocket
    try {
      ws = new WebSocket(url)
    } catch (err) {
      logErr(`ws construct failed: ${err instanceof Error ? err.message : String(err)}`)
      resolve()
      return
    }

    let settled = false
    // Watchdog timers: a connect/idle watchdog (finding #7). If a socket opens
    // and then silently stalls (half-open TCP, no close frame), connectOnce would
    // otherwise never resolve and the supervisor loop would block forever. We
    // force a reconnect if no 'connected'/frame arrives within CONNECT_TIMEOUT,
    // and if no frame is seen for IDLE_TIMEOUT after that.
    const CONNECT_TIMEOUT_MS = 30000
    const IDLE_TIMEOUT_MS = 90000
    let idleTimer: ReturnType<typeof setTimeout> | undefined
    let connectTimer: ReturnType<typeof setTimeout> | undefined
    const clearTimers = () => {
      if (idleTimer) { clearTimeout(idleTimer); idleTimer = undefined }
      if (connectTimer) { clearTimeout(connectTimer); connectTimer = undefined }
    }
    const forceClose = (why: string) => {
      logErr(`watchdog: ${why}; forcing reconnect`)
      try { ws.close() } catch {}
      done()
    }
    const armIdle = () => {
      if (idleTimer) clearTimeout(idleTimer)
      idleTimer = setTimeout(() => forceClose('idle timeout (no frames)'), IDLE_TIMEOUT_MS)
    }
    const done = () => { if (!settled) { settled = true; clearTimers(); resolve() } }

    // If we never see the 'connected' frame, bail and reconnect.
    connectTimer = setTimeout(() => forceClose('connect timeout (no connected frame)'), CONNECT_TIMEOUT_MS)

    ws.addEventListener('open', () => {
      // Subscription opened; wait for the 'connected' frame to confirm.
    })

    ws.addEventListener('message', ev => {
      // Any frame proves liveness: reset the idle watchdog and clear the
      // connect watchdog (we are receiving data).
      if (connectTimer) { clearTimeout(connectTimer); connectTimer = undefined }
      armIdle()
      let frame: any
      try {
        frame = JSON.parse(typeof ev.data === 'string' ? ev.data : String(ev.data))
      } catch {
        return
      }
      switch (frame?.type) {
        case 'connected':
          // Subscription is live.
          chatActive = true
          logErr('connected')
          writeConnectedMarker(state, 'connected')
          break
        case 'chat_active':
          chatActive = true
          logErr('chat_active')
          writeConnectedMarker(state, 'chat_active')
          break
        case 'chat_activation_failed':
          // Terminal: recovery is delete + recreate the chat (operator action).
          logErr('chat_activation_failed (terminal; re-run ./domo activate to provision a new chat)')
          break
        case 'participant_verified':
          logErr('participant_verified')
          break
        case 'message_received':
          handleInboundMessage(frame.message, state, true)
          break
        case 'message_status_updated':
          // Outbound delivery transition; nothing to forward.
          break
        default:
          // Unknown frame; ignore.
          break
      }
    })

    ws.addEventListener('error', () => {
      // Resolve so the supervisor reconnects even if no 'close' follows (e.g. a
      // construct/handshake error). Don't log the token. (finding #7)
      clearConnectedMarker()
      done()
    })

    ws.addEventListener('close', () => {
      clearConnectedMarker()
      done()
    })
  })
}

/**
 * Supervisor loop: connect, and on every disconnect re-mint a ticket and
 * backfill missed messages before reconnecting. Re-reads state lazily each
 * iteration so a late activation is picked up without a restart.
 */
async function inboundLoop(): Promise<void> {
  let warnedNoState = false
  // Backoff between reconnects to avoid hammering on persistent failure.
  let backoffMs = 1000
  const maxBackoffMs = 30000

  for (;;) {
    const state = readState()
    if (!state) {
      if (!warnedNoState) {
        logErr(`state not ready at ${STATE_PATH || '(PLOW_CHAT_STATE unset)'}; run ./domo activate`)
        warnedNoState = true
      }
      await sleep(3000)
      continue
    }
    warnedNoState = false

    // On a (re)connect, backfill first so messages missed while offline are
    // delivered (de-duped). On the very first connect this is a no-op-ish
    // catch-up; seenMessageUids prevents double delivery from the live stream.
    await backfill(state)

    const before = Date.now()
    await connectOnce(state)
    const lasted = Date.now() - before

    // Reset backoff if the connection lasted a while; otherwise grow it.
    if (lasted > 10000) backoffMs = 1000
    else backoffMs = Math.min(backoffMs * 2, maxBackoffMs)

    await sleep(backoffMs)
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise(r => setTimeout(r, ms))
}

// Seed the de-dup set from the persisted high-water mark BEFORE the first
// backfill so prior history is not replayed to Claude on a fresh start (#6).
loadLastSeen()

// Kick off the inbound supervisor. It self-recovers and never rejects, so it
// cannot crash the stdio transport.
void inboundLoop()

// One startup line to stderr (no secrets). Tells the operator the wiring state.
if (readState()) {
  process.stderr.write('plow-chat: state present; connecting to Plow Chat\n')
} else {
  process.stderr.write(`plow-chat: state not ready at ${STATE_PATH || '(PLOW_CHAT_STATE unset)'}; run ./domo activate\n`)
}
