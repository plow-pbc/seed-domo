// Plow activation/group-chat stub for install-UX E2E repros.
//
// Run:
//   PLOW_STUB_STATE_DIR=/tmp/domo-plow-stub bun run ref/installer/plow-stub.ts
//   base_url="$(jq -r .base_url /tmp/domo-plow-stub/server-info)"
//   PLOW_CHAT_BASE_URL="$base_url" ref/installer/domo-install.sh
//
// Covered Plow endpoints:
//   POST /v1/auth/activate
//   POST /v1/auth/activate/redeem
//   GET  /v1/lines
//   POST /v1/chats
//   POST /v1/chats/:chat/invitations/:participant/resend
//   POST /v1/ws/ticket
//   GET  /v1/ws?ticket=...
//
// WSS behavior:
//   - each accepted /v1/ws connection immediately sends {"type":"connected"}
//   - POST /_stub/text with a member VERIFY code emits participant_verified
//   - after the final member verifies, the socket emits chat_active
//
// Test-only helpers:
//   POST /_stub/text       {"text":"<exact activation or VERIFY code>","from":"+1555..."}
//   POST /_stub/config     {"ws_close_on_open":true|false,"response_delay_ms":0}
//   GET  /_stub/calls      counters plus ordered Plow API sequence

import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

type Activation = {
  activationSecret: string;
  displayCode: string;
  sendTo: string;
  lineId: string;
  provisionChat: boolean;
  verified: boolean;
  token: string;
  chatUid: string;
};

type MemberParticipant = {
  type: "member";
  object: "chat_participant";
  uid: string;
  status: "pending_verification" | "active";
  display_name: string;
  provider_type: "imessage";
  provider_key: string | null;
  verification_code: string;
  verification_code_expires_at: string;
  verified_at: string | null;
  joined_at: string | null;
};

type Chat = {
  uid: string;
  object: "chat";
  status: "pending" | "active";
  provider_key: string;
  failure_reason: null;
  participants: Array<Record<string, unknown> | MemberParticipant>;
  created_at: string;
};

type CallRecord = {
  method: string;
  path: string;
};

const line = {
  object: "line",
  uid: "ln_stub_000001",
  provider_type: "imessage",
  provider_key: "+15550001003",
};

const activations = new Map<string, Activation>();
const tokens = new Map<string, Activation>();
const activationCodes = new Map<string, string>();
const chats = new Map<string, Chat>();
const verificationCodes = new Map<string, { chatUid: string; participantUid: string }>();
const tickets = new Map<string, string>();
const sockets = new Set<any>();

const calls: {
  activate: number;
  redeem: number;
  lines: number;
  chats: number;
  resend: number;
  ws_ticket: number;
  ws_connect: number;
  sequence: CallRecord[];
} = { activate: 0, redeem: 0, lines: 0, chats: 0, resend: 0, ws_ticket: 0, ws_connect: 0, sequence: [] };
let wsCloseOnOpen = process.env.PLOW_STUB_WS_CLOSE_ON_OPEN === "1";
let redeemErrorStatus = 0;
let responseDelayMs = 0;

function record(method: string, path: string): void {
  calls.sequence.push({ method, path });
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

function error(status: number, message: string): Response {
  return json({ error: { type: "invalid_request_error", message } }, status);
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function id(prefix: string): string {
  return `${prefix}_${crypto.randomUUID().replaceAll("-", "").slice(0, 12)}`;
}

function code(prefix: string): string {
  return `${prefix}-${crypto.randomUUID().replaceAll("-", "").slice(0, 6).toUpperCase()}`;
}

async function parseJson(req: Request): Promise<Record<string, unknown> | Response> {
  const text = await req.text();
  if (!text.trim()) return {};
  try {
    const body = JSON.parse(text);
    if (!body || typeof body !== "object" || Array.isArray(body)) {
      return error(400, "JSON body must be an object");
    }
    return body as Record<string, unknown>;
  } catch {
    return error(400, "malformed JSON body");
  }
}

function bearer(req: Request): string | null {
  const auth = req.headers.get("authorization") || "";
  const match = auth.match(/^Bearer (.+)$/);
  return match ? match[1] : null;
}

function requireToken(req: Request): Response | Activation {
  const token = bearer(req);
  if (!token) return error(401, "missing Bearer token");
  const activation = tokens.get(token);
  if (!activation) return error(401, "unknown Bearer token");
  return activation;
}

function activationResponse(activation: Activation): Record<string, unknown> {
  return {
    object: "activation",
    activation_secret: activation.activationSecret,
    display_code: activation.displayCode,
    send_to: activation.sendTo,
    line_id: activation.lineId,
  };
}

function createActivation(body: Record<string, unknown>): Response {
  calls.activate++;
  record("POST", "/v1/auth/activate");
  if (typeof body.name !== "string" || body.name.trim() === "") {
    return error(400, "name is required");
  }
  if ("provision_chat" in body && typeof body.provision_chat !== "boolean") {
    return error(400, "provision_chat must be a boolean when provided");
  }
  const activation: Activation = {
    activationSecret: id("actsec"),
    displayCode: code("ACT"),
    sendTo: line.provider_key,
    lineId: line.uid,
    provisionChat: body.provision_chat === true,
    verified: false,
    token: id("plow_stub_token"),
    chatUid: id("cht"),
  };
  activations.set(activation.activationSecret, activation);
  activationCodes.set(activation.displayCode, activation.activationSecret);
  return json(activationResponse(activation));
}

function redeemActivation(body: Record<string, unknown>): Response {
  calls.redeem++;
  record("POST", "/v1/auth/activate/redeem");
  if (redeemErrorStatus) return error(redeemErrorStatus, "simulated redeem failure");
  if (typeof body.activation_secret !== "string" || body.activation_secret.trim() === "") {
    return error(400, "activation_secret is required");
  }
  const activation = activations.get(body.activation_secret);
  if (!activation) return error(404, "unknown activation_secret");
  if (!activation.verified) return json({ status: "pending" });
  tokens.set(activation.token, activation);
  return json({
    status: "verified",
    token: activation.token,
    chat: activation.provisionChat ? { uid: activation.chatUid } : null,
  });
}

function listLines(req: Request): Response {
  calls.lines++;
  record("GET", "/v1/lines");
  const auth = requireToken(req);
  if (auth instanceof Response) return auth;
  return json({ object: "list", data: [line], has_more: false, url: "/v1/lines" });
}

function createChat(req: Request, body: Record<string, unknown>): Response {
  calls.chats++;
  record("POST", "/v1/chats");
  const auth = requireToken(req);
  if (auth instanceof Response) return auth;
  const participants = body.participants;
  if (!Array.isArray(participants)) return error(400, "participants array is required");
  const agents = participants.filter((p) => p && typeof p === "object" && (p as any).type === "agent");
  const members = participants.filter((p) => p && typeof p === "object" && (p as any).type === "member");
  if (agents.length !== 1) return error(400, "exactly one agent participant is required");
  if (members.length < 1) return error(400, "at least one member participant is required");
  if ((agents[0] as any).line_id !== line.uid) return error(400, "agent.line_id is unknown");
  const chatUid = id("cht");
  const memberParticipants: MemberParticipant[] = members.map((member) => {
    const displayName = String((member as any).display_name || "").trim();
    if (!displayName) throw new Error("member.display_name is required");
    return {
      type: "member",
      object: "chat_participant",
      uid: id("cp"),
      status: "pending_verification",
      display_name: displayName,
      provider_type: "imessage",
      provider_key: null,
      verification_code: code("VERIFY"),
      verification_code_expires_at: new Date(Date.now() + 60 * 60 * 1000).toISOString(),
      verified_at: null,
      joined_at: null,
    };
  });
  const chat: Chat = {
    uid: chatUid,
    object: "chat",
    status: "pending",
    provider_key: line.provider_key,
    failure_reason: null,
    participants: [
      { type: "agent", line },
      ...memberParticipants,
    ],
    created_at: new Date().toISOString(),
  };
  chats.set(chat.uid, chat);
  for (const participant of memberParticipants) {
    verificationCodes.set(participant.verification_code, {
      chatUid: chat.uid,
      participantUid: participant.uid,
    });
  }
  return json(chat, 201);
}

function resendInvitation(req: Request, chatUid: string, participantUid: string): Response {
  calls.resend++;
  record("POST", `/v1/chats/${chatUid}/invitations/${participantUid}/resend`);
  const auth = requireToken(req);
  if (auth instanceof Response) return auth;
  const chat = chats.get(chatUid);
  if (!chat) return error(404, "unknown chat");
  const participant = chat.participants.find((p) => (p as any).uid === participantUid) as MemberParticipant | undefined;
  if (!participant || participant.type !== "member") return error(404, "unknown participant");
  if (participant.status === "active") return error(409, "participant already verified");
  verificationCodes.delete(participant.verification_code);
  participant.verification_code = code("VERIFY");
  participant.verification_code_expires_at = new Date(Date.now() + 60 * 60 * 1000).toISOString();
  verificationCodes.set(participant.verification_code, { chatUid, participantUid });
  return json(participant);
}

function mintTicket(req: Request, body: Record<string, unknown>): Response {
  calls.ws_ticket++;
  record("POST", "/v1/ws/ticket");
  const auth = requireToken(req);
  if (auth instanceof Response) return auth;
  if (typeof body.chat_id !== "string" || body.chat_id.trim() === "") {
    return error(400, "chat_id is required");
  }
  if (!chats.has(body.chat_id)) return error(404, "unknown chat_id");
  const ticket = id("wst");
  tickets.set(ticket, body.chat_id);
  return json({ object: "ws_ticket", ticket, expires_at: new Date(Date.now() + 5 * 60 * 1000).toISOString() });
}

function emit(chatUid: string, frame: Record<string, unknown>): void {
  const text = JSON.stringify(frame);
  for (const ws of sockets) {
    if (ws.data?.chatUid === chatUid) ws.send(text);
  }
}

function receiveText(body: Record<string, unknown>): Response {
  const text = String(body.text || "").trim();
  if (activationCodes.has(text)) {
    const activation = activations.get(activationCodes.get(text) || "");
    if (!activation) return error(404, "unknown activation");
    activation.verified = true;
    return json({ status: "verified", display_code: text, activation_secret: activation.activationSecret });
  }
  if (!verificationCodes.has(text)) return error(404, "unknown exact code");
  const { chatUid, participantUid } = verificationCodes.get(text)!;
  const chat = chats.get(chatUid);
  if (!chat) return error(404, "unknown chat");
  const participant = chat.participants.find((p) => (p as any).uid === participantUid) as MemberParticipant | undefined;
  if (!participant) return error(404, "unknown participant");
  participant.status = "active";
  participant.provider_key = body.from ? String(body.from) : `+1555${participant.uid.slice(-6)}`;
  participant.verified_at = new Date().toISOString();
  participant.joined_at = participant.verified_at;
  emit(chat.uid, {
    type: "participant_verified",
    participant: {
      type: "member",
      uid: participant.uid,
      display_name: participant.display_name,
      provider_key: participant.provider_key,
      joined_at: participant.joined_at,
    },
  });
  const allActive = chat.participants
    .filter((p) => (p as any).type === "member")
    .every((p) => (p as MemberParticipant).status === "active");
  if (allActive) {
    chat.status = "active";
    emit(chat.uid, { type: "chat_active", chat: { uid: chat.uid, status: "active" } });
  }
  return json({ status: "verified", chat_uid: chat.uid, participant_uid: participant.uid });
}

const server = Bun.serve({
  hostname: "127.0.0.1",
  port: Number(process.env.PLOW_STUB_PORT || 0),
  async fetch(req, server) {
    if (responseDelayMs > 0 && new URL(req.url).pathname.startsWith("/v1/")) {
      await sleep(responseDelayMs);
    }
    const url = new URL(req.url);
    const { pathname } = url;
    if (pathname === "/healthz" && req.method === "GET") return json({ status: "ok" });
    if (pathname === "/_stub/calls" && req.method === "GET") return json(calls);
    if (pathname === "/_stub/config" && req.method === "POST") {
      const body = await parseJson(req);
      if (body instanceof Response) return body;
      wsCloseOnOpen = body.ws_close_on_open === true;
      redeemErrorStatus = typeof body.redeem_error_status === "number" ? body.redeem_error_status : 0;
      responseDelayMs = typeof body.response_delay_ms === "number" ? body.response_delay_ms : 0;
      return json({ ws_close_on_open: wsCloseOnOpen, redeem_error_status: redeemErrorStatus, response_delay_ms: responseDelayMs });
    }
    if (pathname === "/_stub/text" && req.method === "POST") {
      const body = await parseJson(req);
      if (body instanceof Response) return body;
      return receiveText(body);
    }
    if (pathname === "/v1/auth/activate" && req.method === "POST") {
      const body = await parseJson(req);
      if (body instanceof Response) return body;
      return createActivation(body);
    }
    if (pathname === "/v1/auth/activate/redeem" && req.method === "POST") {
      const body = await parseJson(req);
      if (body instanceof Response) return body;
      return redeemActivation(body);
    }
    if (pathname === "/v1/lines" && req.method === "GET") return listLines(req);
    if (pathname === "/v1/chats" && req.method === "POST") {
      const body = await parseJson(req);
      if (body instanceof Response) return body;
      try {
        return createChat(req, body);
      } catch (err) {
        return error(400, err instanceof Error ? err.message : "invalid chat request");
      }
    }
    {
      const resendMatch = pathname.match(/^\/v1\/chats\/([^/]+)\/invitations\/([^/]+)\/resend$/);
      if (resendMatch && req.method === "POST") return resendInvitation(req, resendMatch[1], resendMatch[2]);
    }
    if (pathname === "/v1/ws/ticket" && req.method === "POST") {
      const body = await parseJson(req);
      if (body instanceof Response) return body;
      return mintTicket(req, body);
    }
    if (pathname === "/v1/ws" && req.method === "GET") {
      calls.ws_connect++;
      record("GET", "/v1/ws");
      const ticket = url.searchParams.get("ticket") || "";
      const chatUid = tickets.get(ticket);
      if (!chatUid) return error(401, "unknown or expired websocket ticket");
      if (server.upgrade(req, { data: { chatUid } })) return undefined;
      return error(500, "websocket upgrade failed");
    }
    if (pathname.startsWith("/v1/")) return error(405, "method or endpoint not allowed");
    return json({ error: "not found" }, 404);
  },
  websocket: {
    open(ws) {
      sockets.add(ws);
      ws.send(JSON.stringify({ type: "connected" }));
      if (wsCloseOnOpen) {
        setTimeout(() => ws.close(1011, "simulated drop"), 25);
      }
    },
    close(ws) {
      sockets.delete(ws);
    },
  },
});

const baseUrl = `http://127.0.0.1:${server.port}`;
const stateDir = process.env.PLOW_STUB_STATE_DIR || join(process.env.TMPDIR || "/tmp", "domo-plow-stub");
mkdirSync(stateDir, { recursive: true });
writeFileSync(join(stateDir, "server-info"), JSON.stringify({ base_url: baseUrl, port: server.port }, null, 2));
console.log(JSON.stringify({ base_url: baseUrl, port: server.port }));
