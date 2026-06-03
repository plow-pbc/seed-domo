// Generic install-dashboard relay server.
//
// Agent- and SEED-agnostic. It serves a single-page app and relays a JSON
// "state object" between a driver (any agent that can spawn a process and make
// HTTP calls) and the page over a plain HTTP/SSE contract. It knows NOTHING
// about Domo, Claude, Codex, Gemini, Plow, connectors, or any SEED specifics —
// all of that lives in the driver. See ref/installer/README.md for the contract.
//
// Hard rules enforced here:
//   - Bind 127.0.0.1 only, on an ephemeral port.
//   - Random URL path token guards /s/<token>/* ; wrong token -> 403.
//   - No secrets ever enter the state object: POST /state runs a no-secret
//     guard and rejects (400) any secret-looking value.
//   - In-memory state only; nothing but server-info is written to disk.

import { randomBytes } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const APP_DIR = new URL("./app/", import.meta.url).pathname;

// ---------------------------------------------------------------------------
// In-memory state (the only state this process holds).
// ---------------------------------------------------------------------------

// The current install state object, as pushed by the driver. `null` until the
// driver pushes its first state.
let state: unknown = null;
let doneExitScheduled = false;

// The submitted form. `submitted` flips to true once the page POSTs /answers.
let answers: { submitted: boolean; values: unknown } = {
  submitted: false,
  values: null,
};

// Connected SSE clients. Each entry can push an already-encoded "data: …\n\n"
// frame to one browser. We fan state changes out to all of them.
type SseClient = { send: (chunk: string) => void; close: () => void };
const clients = new Set<SseClient>();

// ---------------------------------------------------------------------------
// No-secret guard.
//
// Walks a parsed JSON value; returns true if any string looks like a secret.
// Verification codes of the form VERIFY-XXXX are explicitly allowed (they are
// one-time codes meant to be shown).
// ---------------------------------------------------------------------------

const VERIFY_CODE = /^VERIFY-[A-Za-z0-9]+$/;

// Value-shaped secret patterns: a string is rejected if it matches any of
// these regardless of the key it sits under.
const SECRET_VALUE_PATTERNS: RegExp[] = [
  /Bearer /, // HTTP Authorization bearer prefix
  /plow_[A-Za-z0-9_-]{10,}/, // Plow-style token
  /sk-[A-Za-z0-9]{20,}/, // OpenAI-style secret key
  /ghp_[A-Za-z0-9]{20,}/, // GitHub personal access token
  /eyJ[A-Za-z0-9_-]{10,}\./, // JWT (base64url header "{\"alg…" then a dot)
];

// Key names that, when paired with a long opaque value, indicate a credential.
const SENSITIVE_KEY = /token|secret|password|api[_-]?key|key|auth|credential|bearer/i;

// A value is "long opaque" if it has no spaces and is reasonably long — the
// shape of a credential rather than human-readable display text.
function isLongOpaque(value: string): boolean {
  return value.length >= 12 && !/\s/.test(value);
}

// Returns a reason string if a secret-like value is found, else null.
function findSecret(value: unknown, key?: string): string | null {
  if (typeof value === "string") {
    // Allow-list: one-time verification codes are meant to be shown.
    if (VERIFY_CODE.test(value)) return null;
    for (const pattern of SECRET_VALUE_PATTERNS) {
      if (pattern.test(value)) return "secret-like value rejected";
    }
    if (key && SENSITIVE_KEY.test(key) && isLongOpaque(value)) {
      return "secret-like value rejected";
    }
    return null;
  }
  if (Array.isArray(value)) {
    for (const item of value) {
      const found = findSecret(item, key);
      if (found) return found;
    }
    return null;
  }
  if (value && typeof value === "object") {
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      const found = findSecret(v, k);
      if (found) return found;
    }
    return null;
  }
  return null;
}

// ---------------------------------------------------------------------------
// SSE fan-out.
// ---------------------------------------------------------------------------

function stateFrame(): string {
  return `data: ${JSON.stringify(state)}\n\n`;
}

function broadcastState(): void {
  const frame = stateFrame();
  for (const client of clients) {
    try {
      client.send(frame);
    } catch {
      // A dead client will be cleaned up by its stream's cancel handler.
    }
  }
}

// ---------------------------------------------------------------------------
// Static asset serving.
// ---------------------------------------------------------------------------

const TOKEN = randomBytes(16).toString("hex");

function injectToken(html: string): string {
  // Support multiple ways for the SPA to learn the token, so it works
  // regardless of how index.html is authored. We replace placeholder VALUES
  // only — never bare identifiers — so an existing `window.__TOKEN__` variable
  // name in the page is left intact:
  //   1) a literal %TOKEN% placeholder (the value slot), e.g.
  //      <script>window.__TOKEN__ = "%TOKEN%";</script>
  //   2) a quoted "__TOKEN__" placeholder value, and
  //   3) a defensive injected <script> setting window.__TOKEN__ (added before
  //      </head>, or prepended if there is no <head>) as a fallback for a page
  //      that uses neither placeholder.
  let out = html.split("%TOKEN%").join(TOKEN);
  out = out.split('"__TOKEN__"').join(JSON.stringify(TOKEN));
  const tag = `<script>window.__TOKEN__=${JSON.stringify(TOKEN)};</script>`;
  if (out.includes("</head>")) {
    out = out.replace("</head>", `${tag}</head>`);
  } else {
    out = tag + out;
  }
  return out;
}

async function serveIndex(): Promise<Response> {
  const file = Bun.file(join(APP_DIR, "index.html"));
  if (!(await file.exists())) {
    return new Response("index.html not found", { status: 404 });
  }
  const html = await file.text();
  return new Response(injectToken(html), {
    headers: { "content-type": "text/html; charset=utf-8" },
  });
}

async function serveAsset(name: string, contentType: string): Promise<Response> {
  const file = Bun.file(join(APP_DIR, name));
  if (!(await file.exists())) {
    return new Response("not found", { status: 404 });
  }
  return new Response(file, { headers: { "content-type": contentType } });
}

// ---------------------------------------------------------------------------
// JSON helper.
// ---------------------------------------------------------------------------

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

// ---------------------------------------------------------------------------
// SSE endpoint.
// ---------------------------------------------------------------------------

function eventsResponse(): Response {
  let client: SseClient;
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      const encoder = new TextEncoder();
      client = {
        send: (chunk: string) => controller.enqueue(encoder.encode(chunk)),
        close: () => {
          try {
            controller.close();
          } catch {
            // already closed
          }
        },
      };
      clients.add(client);
      // On connect, send the current state immediately.
      client.send(stateFrame());
      // Keep-alive comment so proxies / the browser keep the stream open.
      const keepAlive = setInterval(() => {
        try {
          client.send(`: keep-alive\n\n`);
        } catch {
          clearInterval(keepAlive);
        }
      }, 15000);
      (client as SseClient & { keepAlive?: ReturnType<typeof setInterval> })
        .keepAlive = keepAlive;
    },
    cancel() {
      clients.delete(client);
      const ka = (client as SseClient & {
        keepAlive?: ReturnType<typeof setInterval>;
      }).keepAlive;
      if (ka) clearInterval(ka);
    },
  });
  return new Response(stream, {
    headers: {
      "content-type": "text/event-stream",
      "cache-control": "no-cache, no-transform",
      connection: "keep-alive",
    },
  });
}

// ---------------------------------------------------------------------------
// Token-guarded handlers.
// ---------------------------------------------------------------------------

async function handleState(req: Request): Promise<Response> {
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid JSON" }, 400);
  }
  // No-secret guard: reject any secret-looking value before storing.
  if (findSecret(body)) {
    return json({ error: "secret-like value rejected" }, 400);
  }
  state = body;
  broadcastState();
  // Ephemeral: once the install reaches `done`, the dashboard's job is over.
  // Self-exit after a short grace period so the user can read the success screen
  // and the page can finish rendering — then the server stops listening on its
  // own instead of orphaning (start.sh detaches it, so nothing else reaps it).
  // Overridable via INSTALLER_DONE_GRACE_MS (0 disables the auto-exit).
  if (body && typeof body === "object" && (body as Record<string, unknown>).done === true) {
    const grace = Number(process.env.INSTALLER_DONE_GRACE_MS ?? 90000);
    if (grace > 0 && !doneExitScheduled) {
      doneExitScheduled = true;
      setTimeout(() => process.exit(0), grace);
    }
  }
  return json({ ok: true });
}

async function handleAnswersPost(req: Request): Promise<Response> {
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid JSON" }, 400);
  }
  // Accept either a bare field-map or a {values:{...}} envelope, and store the
  // field map DIRECTLY (per the contract: GET /answers returns values = the map).
  const values =
    body && typeof body === "object" && "values" in (body as Record<string, unknown>)
      ? (body as Record<string, unknown>).values
      : body;
  answers = { submitted: true, values };
  // Reflect submission in the live state so the page updates, if a form exists.
  if (state && typeof state === "object") {
    const s = state as Record<string, unknown>;
    if (s.form && typeof s.form === "object") {
      (s.form as Record<string, unknown>).submitted = true;
    }
  }
  broadcastState();
  return json({ ok: true });
}

function handleAnswersGet(): Response {
  return json({ submitted: answers.submitted, values: answers.values });
}

// ---------------------------------------------------------------------------
// Router.
// ---------------------------------------------------------------------------

const server = Bun.serve({
  hostname: "127.0.0.1",
  port: 0,
  // Keep SSE connections from being timed out by Bun's idle timeout.
  idleTimeout: 0,
  async fetch(req) {
    const url = new URL(req.url);
    const { pathname } = url;

    // --- Unauthenticated routes -------------------------------------------
    if (pathname === "/" && req.method === "GET") {
      return serveIndex();
    }
    if (pathname === "/app.js" && req.method === "GET") {
      return serveAsset("app.js", "text/javascript; charset=utf-8");
    }
    if (pathname === "/style.css" && req.method === "GET") {
      return serveAsset("style.css", "text/css; charset=utf-8");
    }
    if (pathname === "/healthz" && req.method === "GET") {
      return json({ status: "ok" });
    }

    // --- Token-guarded routes: /s/<token>/... -----------------------------
    const parts = pathname.split("/").filter(Boolean); // ["s", token, action]
    if (parts[0] === "s") {
      const token = parts[1];
      const action = parts[2];
      if (token !== TOKEN) {
        return json({ error: "forbidden" }, 403);
      }
      if (action === "events" && req.method === "GET") {
        return eventsResponse();
      }
      if (action === "state" && req.method === "POST") {
        return handleState(req);
      }
      if (action === "answers") {
        if (req.method === "POST") return handleAnswersPost(req);
        if (req.method === "GET") return handleAnswersGet();
      }
      return json({ error: "not found" }, 404);
    }

    return json({ error: "not found" }, 404);
  },
});

// ---------------------------------------------------------------------------
// Server-info: write to disk and print to stdout on startup.
// ---------------------------------------------------------------------------

const port = server.port;
const base = `http://127.0.0.1:${port}`;
const serverInfo = {
  url: base,
  port,
  token: TOKEN,
  events_url: `${base}/s/${TOKEN}/events`,
  state_url: `${base}/s/${TOKEN}/state`,
  answers_url: `${base}/s/${TOKEN}/answers`,
};

// Agent/SEED-agnostic storage dir. INSTALLER_STATE_DIR is the canonical name;
// DOMO_INSTALLER_STATE_DIR is honored as a back-compat alias.
const stateDir =
  process.env.INSTALLER_STATE_DIR ||
  process.env.DOMO_INSTALLER_STATE_DIR ||
  join(process.env.TMPDIR || "/tmp", "installer-ui");
mkdirSync(stateDir, { recursive: true });
writeFileSync(join(stateDir, "server-info"), JSON.stringify(serverInfo, null, 2));

// Print the same JSON to stdout so a driver that captured stdout can read it
// without touching the filesystem.
console.log(JSON.stringify(serverInfo));
