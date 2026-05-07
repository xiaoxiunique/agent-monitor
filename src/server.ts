import { spawnSync } from "node:child_process";
import { createReadStream } from "node:fs"; import { stat } from "node:fs/promises"; import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { extname, normalize, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import pty from "node-pty";
import { WebSocket, WebSocketServer } from "ws";

const DEFAULT_PORT = 8787;
const DEFAULT_HOST = "0.0.0.0";
const FIELD_SEPARATOR = "\t";

type PaneStatus = "running" | "waiting" | "idle" | "failed" | "done";

type Pane = {
  id: string;
  target: string;
  session: string;
  windowIndex: string;
  windowName: string;
  paneIndex: string;
  command: string;
  path: string;
  active: boolean;
  pid: number | null;
  title: string;
  tail: string;
  status: PaneStatus;
  reason: string;
  updatedAt: string;
};

type Snapshot = {
  ok: boolean;
  now: string;
  panes: Pane[];
  error?: string;
};

type Client = {
  send(payload: unknown): void;
};

const host = process.env.AGENT_MONITOR_HOST ?? DEFAULT_HOST;
const port = Number(process.env.AGENT_MONITOR_PORT ?? DEFAULT_PORT);
const token = process.env.AGENT_MONITOR_TOKEN ?? "";
const publicUrls = (process.env.AGENT_MONITOR_PUBLIC_URLS ?? "")
  .split(",")
  .map((item) => item.trim())
  .filter(Boolean);
const rootDir = resolve(fileURLToPath(new URL("..", import.meta.url)));
const publicDir = resolve(rootDir, "public");

let lastSnapshot: Snapshot = {
  ok: true,
  now: new Date().toISOString(),
  panes: [],
};
const clients = new Set<Client>();

function sendJson(res: ServerResponse, data: unknown, status = 200): void {
  res.writeHead(status, { "content-type": "application/json; charset=utf-8" });
  res.end(JSON.stringify(data));
}

function runTmux(args: string[]): { ok: true; stdout: string } | { ok: false; error: string } {
  const result = spawnSync("tmux", args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });

  if (result.status !== 0) {
    return {
      ok: false,
      error: result.stderr.trim() || `tmux exited with ${result.status}`,
    };
  }

  return {
    ok: true,
    stdout: result.stdout,
  };
}

function listPanes(): { ok: true; panes: Omit<Pane, "tail" | "status" | "reason" | "updatedAt">[] } | { ok: false; error: string } {
  const format = [
    "#{session_name}",
    "#{window_index}",
    "#{window_name}",
    "#{pane_index}",
    "#{pane_id}",
    "#{pane_current_command}",
    "#{pane_current_path}",
    "#{pane_active}",
    "#{pane_pid}",
    "#{pane_title}",
  ].join(FIELD_SEPARATOR);

  const result = runTmux(["list-panes", "-a", "-F", format]);
  if (!result.ok) return result;

  const panes = result.stdout
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((line) => {
      const [
        session,
        windowIndex,
        windowName,
        paneIndex,
        id,
        command,
        path,
        active,
        pid,
        title,
      ] = line.split(FIELD_SEPARATOR);

      return {
        id,
        target: `${session}:${windowIndex}.${paneIndex}`,
        session,
        windowIndex,
        windowName,
        paneIndex,
        command,
        path,
        active: active === "1",
        pid: pid ? Number(pid) : null,
        title: title || command,
      };
    });

  return { ok: true, panes };
}

function capturePane(paneId: string): string {
  const result = runTmux(["capture-pane", "-p", "-J", "-S", "-300", "-t", paneId]);
  if (!result.ok) return "";
  return result.stdout.trimEnd();
}

function pasteText(paneId: string, text: string): { ok: true; stdout: string } | { ok: false; error: string } {
  const bufferName = `agent-monitor-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  const setBuffer = runTmux(["set-buffer", "-b", bufferName, "--", text]);
  if (!setBuffer.ok) return setBuffer;

  const paste = runTmux(["paste-buffer", "-d", "-p", "-b", bufferName, "-t", paneId]);
  if (!paste.ok) {
    runTmux(["delete-buffer", "-b", bufferName]);
    return paste;
  }

  return paste;
}

function inferStatus(pane: Omit<Pane, "tail" | "status" | "reason" | "updatedAt">, tail: string): { status: PaneStatus; reason: string } {
  const lower = tail.toLowerCase();
  const recent = tail.split("\n").slice(-18).join("\n").toLowerCase();

  if (/\b(exit|exited)\s+(1|2|101|127|128)\b|failed|error:|panic:|exception|traceback/.test(recent)) {
    return { status: "failed", reason: "recent output looks like a failure" };
  }

  if (/do you want|proceed\?|continue\?|confirm|yes\/no|\by\/n\b|\(y\/n\)|allow\?|approve/.test(recent)) {
    return { status: "waiting", reason: "looks like it needs input" };
  }

  if (/success|completed|done|finished|tests passed|all checks passed/.test(recent)) {
    return { status: "done", reason: "recent output looks complete" };
  }

  if (["claude", "codex", "node", "bun", "npm", "pnpm", "yarn", "zig", "cargo", "python"].includes(pane.command)) {
    return { status: "running", reason: `${pane.command} is active` };
  }

  if (lower.length === 0 || ["zsh", "bash", "fish", "nu"].includes(pane.command)) {
    return { status: "idle", reason: "shell pane" };
  }

  return { status: "running", reason: `${pane.command || "process"} is active` };
}

function buildSnapshot(): Snapshot {
  const listed = listPanes();
  const now = new Date().toISOString();

  if (!listed.ok) {
    return {
      ok: false,
      now,
      panes: [],
      error: listed.error,
    };
  }

  const panes = listed.panes.map((pane) => {
    const tail = capturePane(pane.id);
    const inferred = inferStatus(pane, tail);
    return {
      ...pane,
      tail,
      ...inferred,
      updatedAt: now,
    };
  });

  return { ok: true, now, panes };
}

function broadcast(snapshot: Snapshot): void {
  for (const client of clients) {
    client.send({ type: "snapshot", snapshot });
  }
}

function refreshSnapshot(): void {
  lastSnapshot = buildSnapshot();
  broadcast(lastSnapshot);
}

function requestUrl(req: IncomingMessage): URL {
  return new URL(req.url ?? "/", `http://${req.headers.host ?? `${host}:${port}`}`);
}

function isAuthed(req: IncomingMessage): boolean {
  if (!token) return true;

  const url = requestUrl(req);
  const auth = req.headers.authorization;
  return url.searchParams.get("token") === token || auth === `Bearer ${token}`;
}

function readJson(req: IncomingMessage): Promise<unknown> {
  return new Promise((resolveJson) => {
    let raw = "";
    req.setEncoding("utf8");
    req.on("data", (chunk) => {
      raw += chunk;
      if (raw.length > 64_000) req.destroy();
    });
    req.on("end", () => {
      try {
        resolveJson(raw ? JSON.parse(raw) : null);
      } catch {
        resolveJson(null);
      }
    });
    req.on("error", () => resolveJson(null));
  });
}

function contentType(pathname: string): string {
  switch (extname(pathname)) {
    case ".css":
      return "text/css; charset=utf-8";
    case ".js":
      return "application/javascript; charset=utf-8";
    case ".html":
      return "text/html; charset=utf-8";
    case ".webmanifest":
      return "application/manifest+json; charset=utf-8";
    default:
      return "application/octet-stream";
  }
}

async function serveFile(res: ServerResponse, filePath: string): Promise<void> {
  try {
    const info = await stat(filePath);
    if (!info.isFile()) throw new Error("not a file");
    res.writeHead(200, {
      "content-type": contentType(filePath),
      "content-length": info.size,
    });
    createReadStream(filePath).pipe(res);
  } catch {
    res.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
    res.end("Not found");
  }
}

async function serveStatic(req: IncomingMessage, res: ServerResponse, pathname: string): Promise<void> {
  const vendor: Record<string, string> = {
    "/vendor/xterm.css": resolve(rootDir, "node_modules/@xterm/xterm/css/xterm.css"),
    "/vendor/xterm.js": resolve(rootDir, "node_modules/@xterm/xterm/lib/xterm.js"),
    "/vendor/addon-fit.js": resolve(rootDir, "node_modules/@xterm/addon-fit/lib/addon-fit.js"),
  };

  if (vendor[pathname]) {
    await serveFile(res, vendor[pathname]);
    return;
  }

  const safePath = pathname === "/" ? "index.html" : pathname.replace(/^\/+/, "");
  const filePath = resolve(publicDir, normalize(safePath));
  if (!filePath.startsWith(publicDir)) {
    res.writeHead(404);
    res.end("Not found");
    return;
  }

  await serveFile(res, filePath);
}

async function handleSend(req: IncomingMessage, res: ServerResponse): Promise<void> {
  if (!isAuthed(req)) return sendJson(res, { error: "unauthorized" }, 401);

  const body = await readJson(req) as {
    paneId?: string;
    text?: string;
    enter?: boolean;
    vimMode?: boolean;
  } | null;

  if (!body?.paneId || typeof body.text !== "string") {
    return sendJson(res, { error: "paneId and text are required" }, 400);
  }

  if (body.text.length > 4000) {
    return sendJson(res, { error: "text is too long" }, 400);
  }

  if (body.vimMode) {
    const escape = runTmux(["send-keys", "-t", body.paneId, "C-["]);
    if (!escape.ok) return sendJson(res, { error: escape.error }, 500);

    const insert = runTmux(["send-keys", "-t", body.paneId, "i"]);
    if (!insert.ok) return sendJson(res, { error: insert.error }, 500);
  }

  const sendText = pasteText(body.paneId, body.text);
  if (!sendText.ok) return sendJson(res, { error: sendText.error }, 500);

  if (body.enter !== false) {
    const sendEnter = runTmux(["send-keys", "-t", body.paneId, "Enter"]);
    if (!sendEnter.ok) return sendJson(res, { error: sendEnter.error }, 500);
  }

  refreshSnapshot();
  return sendJson(res, { ok: true });
}

function handleKey(req: IncomingMessage, res: ServerResponse): void {
  if (!isAuthed(req)) return sendJson(res, { error: "unauthorized" }, 401);

  const url = requestUrl(req);
  const paneId = url.searchParams.get("paneId");
  const key = url.searchParams.get("key");
  const allowed = new Set(["Enter", "C-c", "C-d", "C-[", "Escape", "Up", "Down", "BSpace", "C-u", "VimClear", "VimBackspace"]);

  if (!paneId || !key || !allowed.has(key)) {
    return sendJson(res, { error: "invalid paneId or key" }, 400);
  }

  if (key === "VimClear") {
    for (const part of ["C-[", "0", "D", "i"]) {
      const result = runTmux(["send-keys", "-t", paneId, part]);
      if (!result.ok) return sendJson(res, { error: result.error }, 500);
    }

    refreshSnapshot();
    return sendJson(res, { ok: true });
  }

  if (key === "VimBackspace") {
    for (const part of ["C-[", "i", "BSpace"]) {
      const result = runTmux(["send-keys", "-t", paneId, part]);
      if (!result.ok) return sendJson(res, { error: result.error }, 500);
    }

    refreshSnapshot();
    return sendJson(res, { ok: true });
  }

  const result = runTmux(["send-keys", "-t", paneId, key]);
  if (!result.ok) return sendJson(res, { error: result.error }, 500);

  refreshSnapshot();
  return sendJson(res, { ok: true });
}

async function handleKillSession(req: IncomingMessage, res: ServerResponse): Promise<void> {
  if (!isAuthed(req)) return sendJson(res, { error: "unauthorized" }, 401);

  const body = await readJson(req) as {
    session?: string;
  } | null;

  if (!body?.session) {
    return sendJson(res, { error: "session is required" }, 400);
  }

  const result = runTmux(["kill-session", "-t", body.session]);
  if (!result.ok) return sendJson(res, { error: result.error }, 500);

  refreshSnapshot();
  return sendJson(res, { ok: true });
}

const httpServer = createServer(async (req, res) => {
  const url = requestUrl(req);

  if (url.pathname === "/api/snapshot") {
    if (!isAuthed(req)) return sendJson(res, { error: "unauthorized" }, 401);
    refreshSnapshot();
    return sendJson(res, lastSnapshot);
  }

  if (url.pathname === "/api/send" && req.method === "POST") {
    return handleSend(req, res);
  }

  if (url.pathname === "/api/key" && req.method === "POST") {
    return handleKey(req, res);
  }

  if (url.pathname === "/api/session/kill" && req.method === "POST") {
    return handleKillSession(req, res);
  }

  if (req.method === "GET" || req.method === "HEAD") {
    return serveStatic(req, res, url.pathname);
  }

  res.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
  res.end("Not found");
});

const snapshotWss = new WebSocketServer({ noServer: true });
const terminalWss = new WebSocketServer({ noServer: true });

snapshotWss.on("connection", (ws) => {
  const client: Client = {
    send(payload) {
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify(payload));
      }
    },
  };

  clients.add(client);
  client.send({ type: "hello", snapshot: lastSnapshot });
  ws.on("close", () => clients.delete(client));
});

terminalWss.on("connection", (ws, req) => {
  const url = requestUrl(req);
  refreshSnapshot();

  const paneId = url.searchParams.get("paneId");
  const requestedCols = Number(url.searchParams.get("cols") ?? "96");
  const requestedRows = Number(url.searchParams.get("rows") ?? "28");
  const pane = lastSnapshot.panes.find((item) => item.id === paneId);

  if (!pane) {
    ws.send(JSON.stringify({ type: "error", error: "pane not found" }));
    ws.close();
    return;
  }

  runTmux(["select-window", "-t", `${pane.session}:${pane.windowIndex}`]);
  runTmux(["select-pane", "-t", pane.id]);

  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (typeof value === "string" && key !== "TMUX" && key !== "TMUX_PANE") {
      env[key] = value;
    }
  }
  env.TERM = "xterm-256color";

  const term = pty.spawn("tmux", ["attach-session", "-t", pane.session], {
    name: "xterm-256color",
    cols: Number.isFinite(requestedCols) ? Math.max(20, Math.min(240, requestedCols)) : 96,
    rows: Number.isFinite(requestedRows) ? Math.max(8, Math.min(80, requestedRows)) : 28,
    cwd: pane.path || process.cwd(),
    env,
  });

  let pendingOutput = "";
  let flushTimer: NodeJS.Timeout | null = null;
  const flushOutput = () => {
    flushTimer = null;
    if (!pendingOutput || ws.readyState !== WebSocket.OPEN) return;
    const data = pendingOutput;
    pendingOutput = "";
    ws.send(JSON.stringify({ type: "data", data }));
  };

  const dataDisposable = term.onData((data) => {
    if (ws.readyState !== WebSocket.OPEN) return;

    pendingOutput += data;
    if (pendingOutput.length > 32_000) {
      if (flushTimer) {
        clearTimeout(flushTimer);
      }
      flushOutput();
      return;
    }

    if (!flushTimer) {
      flushTimer = setTimeout(flushOutput, 16);
    }
  });

  term.onExit(({ exitCode, signal }) => {
    if (flushTimer) {
      clearTimeout(flushTimer);
      flushOutput();
    }
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: "exit", exitCode, signal }));
      ws.close();
    }
  });

  ws.on("message", (raw) => {
    let message: { type?: string; data?: string; cols?: number; rows?: number } | null = null;
    try {
      message = JSON.parse(raw.toString());
    } catch {
      return;
    }
    if (!message) return;

    if (message.type === "input" && typeof message.data === "string") {
      term.write(message.data);
      return;
    }

    if (message.type === "resize" && Number.isFinite(message.cols) && Number.isFinite(message.rows)) {
      term.resize(
        Math.max(20, Math.min(240, Number(message.cols))),
        Math.max(8, Math.min(80, Number(message.rows))),
      );
    }
  });

  ws.on("close", () => {
    if (flushTimer) {
      clearTimeout(flushTimer);
      flushTimer = null;
    }
    dataDisposable.dispose();
    term.kill();
  });
});

httpServer.on("upgrade", (req, socket, head) => {
  const url = requestUrl(req);

  if (!isAuthed(req)) {
    socket.write("HTTP/1.1 401 Unauthorized\r\n\r\n");
    socket.destroy();
    return;
  }

  if (url.pathname === "/ws") {
    snapshotWss.handleUpgrade(req, socket, head, (ws) => {
      snapshotWss.emit("connection", ws, req);
    });
    return;
  }

  if (url.pathname === "/terminal/ws") {
    terminalWss.handleUpgrade(req, socket, head, (ws) => {
      terminalWss.emit("connection", ws, req);
    });
    return;
  }

  socket.write("HTTP/1.1 404 Not Found\r\n\r\n");
  socket.destroy();
});

refreshSnapshot();
setInterval(refreshSnapshot, 2500);

httpServer.listen(port, host, () => {
  console.log(`Agent Monitor listening on http://${host}:${port}`);
  if (publicUrls.length > 0) {
    console.log("Open:");
    for (const url of publicUrls) {
      console.log(`  ${url}/`);
    }
  } else {
    console.log(`Open: http://${host}:${port}/`);
  }
  if (token) {
    console.log("Token auth is enabled by AGENT_MONITOR_TOKEN.");
  } else {
    console.log("Token auth is disabled. Set AGENT_MONITOR_TOKEN to require a token.");
  }
});
