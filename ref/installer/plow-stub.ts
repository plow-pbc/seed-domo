// Minimal Plow activation stub for install-UX chunk repros.
//
// Covered Plow endpoints:
//   POST /v1/auth/activate
//   POST /v1/auth/activate/redeem
//
// Test-only helper:
//   POST /_stub/text  {"text":"<display_code>"}  marks the activation verified.

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

const activations = new Map<string, Activation>();
const codes = new Map<string, string>();

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

function id(prefix: string): string {
  return `${prefix}_${crypto.randomUUID().replaceAll("-", "").slice(0, 12)}`;
}

async function parseBody(req: Request): Promise<Record<string, unknown>> {
  try {
    return await req.json();
  } catch {
    return {};
  }
}

function createActivation(body: Record<string, unknown>): Response {
  const activationSecret = id("actsec");
  const displayCode = `ACT-${crypto.randomUUID().replaceAll("-", "").slice(0, 6).toUpperCase()}`;
  const activation: Activation = {
    activationSecret,
    displayCode,
    sendTo: "+15550001003",
    lineId: id("ln"),
    provisionChat: body.provision_chat === true,
    verified: false,
    token: id("plow_stub_token"),
    chatUid: id("cht"),
  };
  activations.set(activationSecret, activation);
  codes.set(displayCode, activationSecret);
  return json({
    object: "activation",
    activation_secret: activation.activationSecret,
    display_code: activation.displayCode,
    send_to: activation.sendTo,
    line_id: activation.lineId,
  });
}

function redeemActivation(body: Record<string, unknown>): Response {
  const activationSecret = String(body.activation_secret || "");
  const activation = activations.get(activationSecret);
  if (!activation) return json({ error: "unknown activation_secret" }, 404);
  if (!activation.verified) return json({ status: "pending" });
  return json({
    status: "verified",
    token: activation.token,
    chat: activation.provisionChat ? { uid: activation.chatUid } : null,
  });
}

function receiveText(body: Record<string, unknown>): Response {
  const text = String(body.text || body.body || "").trim();
  const displayCode = [...codes.keys()].find((code) => text.includes(code));
  if (!displayCode) return json({ error: "unknown display_code" }, 404);
  const activation = activations.get(codes.get(displayCode) || "");
  if (!activation) return json({ error: "unknown activation" }, 404);
  activation.verified = true;
  return json({
    status: "verified",
    display_code: displayCode,
    activation_secret: activation.activationSecret,
  });
}

const server = Bun.serve({
  hostname: "127.0.0.1",
  port: Number(process.env.PLOW_STUB_PORT || 0),
  async fetch(req) {
    const url = new URL(req.url);
    if (url.pathname === "/healthz" && req.method === "GET") {
      return json({ status: "ok" });
    }
    if (url.pathname === "/v1/auth/activate" && req.method === "POST") {
      return createActivation(await parseBody(req));
    }
    if (url.pathname === "/v1/auth/activate/redeem" && req.method === "POST") {
      return redeemActivation(await parseBody(req));
    }
    if (url.pathname === "/_stub/text" && req.method === "POST") {
      return receiveText(await parseBody(req));
    }
    return json({ error: "not found" }, 404);
  },
});

const baseUrl = `http://127.0.0.1:${server.port}`;
const stateDir = process.env.PLOW_STUB_STATE_DIR || join(process.env.TMPDIR || "/tmp", "domo-plow-stub");
mkdirSync(stateDir, { recursive: true });
writeFileSync(join(stateDir, "server-info"), JSON.stringify({ base_url: baseUrl, port: server.port }, null, 2));
console.log(JSON.stringify({ base_url: baseUrl, port: server.port }));
