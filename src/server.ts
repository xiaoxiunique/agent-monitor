import { spawnSync } from "node:child_process";
import { mkdir, writeFile } from "node:fs/promises";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { basename, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import pty from "node-pty";
import { WebSocket, WebSocketServer } from "ws";

const DEFAULT_PORT = 8787;
const DEFAULT_HOST = "0.0.0.0";
const FIELD_SEPARATOR = "\t";

type PaneStatus = "running" | "waiting" | "idle" | "failed" | "done";

type InteractionMessageRole = "agent" | "user" | "system";
type InteractionMessageKind =
  | "summary"
  | "status"
  | "question"
  | "permission_request"
  | "progress"
  | "error"
  | "done"
  | "notification";

type InteractionMessage = {
  id: string;
  paneId: string;
  role: InteractionMessageRole;
  kind: InteractionMessageKind;
  priority: "low" | "normal" | "high";
  title: string;
  body: string;
  actions?: Array<{
    label: string;
    payload: string;
    style?: "default" | "destructive";
  }>;
  source?: {
    type: "log";
    excerpt: string;
  };
  createdAt: string;
};

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
  messages: InteractionMessage[];
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
const deepSeekApiKey = process.env.AGENT_MONITOR_DEEPSEEK_API_KEY ?? process.env.DEEPSEEK_API_KEY ?? "";
const deepSeekBaseUrl = process.env.AGENT_MONITOR_DEEPSEEK_BASE_URL ?? process.env.DEEPSEEK_BASE_URL ?? "https://api.deepseek.com";
const deepSeekModel = process.env.AGENT_MONITOR_DEEPSEEK_MODEL ?? process.env.DEEPSEEK_MODEL ?? "deepseek-v4-flash";
const rootDir = resolve(fileURLToPath(new URL("..", import.meta.url)));

let lastSnapshot: Snapshot = {
  ok: true,
  now: new Date().toISOString(),
  panes: [],
};
const clients = new Set<Client>();
const paneLogRefreshers = new Map<string, Set<() => void>>();
const paneLogRefreshBurstTimers = new Map<string, Set<ReturnType<typeof setTimeout>>>();
let scheduledSnapshotRefreshTimer: ReturnType<typeof setTimeout> | null = null;
const paneActivity = new Map<string, { tailHash: string; changedAt: number }>();
const messageCache = new Map<string, InteractionMessage[]>();
const pendingMessageInterpretations = new Set<string>();
const paneLogRefreshBurstDelaysMs = [0, 80, 180, 360, 700, 1200, 2200, 3800] as const;
const paneCommandTailSettleDelaysMs = [0, 80, 180, 360, 700] as const;
const paneCommandTailLineCount = 800;

type RefinedTextResponse = {
  ok: boolean;
  text: string;
  changed: boolean;
  fallback?: boolean;
  error?: string;
};

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

type BasePane = Omit<Pane, "tail" | "status" | "reason" | "updatedAt" | "messages">;

function listPanes(): { ok: true; panes: BasePane[] } | { ok: false; error: string } {
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

function capturePane(paneId: string, lines = 300): string {
  const safeLines = Math.max(50, Math.min(5000, Math.floor(lines)));
  const result = runTmux(["capture-pane", "-p", "-J", "-S", `-${safeLines}`, "-t", paneId]);
  if (result.ok && result.stdout.trim().length > 0) return result.stdout.trimEnd();

  const alternate = runTmux(["capture-pane", "-p", "-a", "-q", "-J", "-S", `-${safeLines}`, "-t", paneId]);
  if (alternate.ok) return alternate.stdout.trimEnd();
  return result.ok ? result.stdout.trimEnd() : "";
}

function contextLineCount(value: string | null): number {
  const parsed = Number(value ?? "1200");
  if (!Number.isFinite(parsed)) return 1200;
  return Math.max(100, Math.min(5000, Math.floor(parsed)));
}

function paneLogLineCount(value: string | null): number {
  const parsed = Number(value ?? "300");
  if (!Number.isFinite(parsed)) return 300;
  return Math.max(50, Math.min(1000, Math.floor(parsed)));
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

function isCodexPane(pane: Pick<BasePane, "session" | "command" | "title">, tail = "") {
  const haystack = `${pane.session}\n${pane.command}\n${pane.title}\n${tail}`.toLowerCase();
  return pane.session.startsWith("cx_") || pane.command === "codex" || /\b(codex|gpt-[\w.-]+)/.test(haystack);
}

function inferStatus(
  pane: BasePane,
  tail: string,
  changedRecently: boolean,
): { status: PaneStatus; reason: string } {
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

  const agentLike = ["claude"].includes(pane.command) || /claude/.test(`${pane.session}\n${pane.title}\n${tail}`.toLowerCase()) || isCodexPane(pane, tail);
  const liveAgentWork = /\b(working|thinking|running)\s*\([^)]*(esc to interrupt|\/stop to close)/i.test(recent);

  if (agentLike && liveAgentWork) {
    return { status: "running", reason: "agent reports active work" };
  }

  if (changedRecently) {
    return { status: "running", reason: "recent output changed" };
  }

  if (agentLike) {
    return { status: "idle", reason: "agent pane has no recent output" };
  }

  if (lower.length === 0 || ["zsh", "bash", "fish", "nu"].includes(pane.command)) {
    return { status: "idle", reason: "shell pane" };
  }

  return { status: "running", reason: `${pane.command || "process"} is active` };
}

function tailHash(value: string) {
  let hash = 2166136261;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }
  return hash.toString(16);
}

function stripTerminalNoise(value: string) {
  return value.replace(/\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])/g, "");
}

function activityFingerprint(tail: string) {
  return tail
    .split("\n")
    .map(stripTerminalNoise)
    .map((line) => line.replace(/[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]/g, "").trim())
    .filter((line) => line.length > 0)
    .filter((line) => !/^[╭╮╰╯│─\s]+$/.test(line))
    .filter((line) => !/^─\s*worked for\b/i.test(line))
    .filter((line) => !/^›\s/.test(line))
    .filter((line) => !/context\s+\d+(?:\.\d+)?%\s+used/i.test(line))
    .filter((line) => !/\b(working|thinking|running)\s*\([^)]*\).*(esc to interrupt|\/stop to close)/i.test(line))
    .filter((line) => !/^\d+:\s*".*"$/.test(line))
    .slice(-24)
    .join("\n");
}

function trackPaneActivity(paneId: string, tail: string, nowMs: number) {
  const hash = tailHash(activityFingerprint(tail));
  const previous = paneActivity.get(paneId);
  if (!previous || previous.tailHash !== hash) {
    paneActivity.set(paneId, { tailHash: hash, changedAt: nowMs });
    return Boolean(previous);
  }
  return false;
}

function cleanTaskTitle(value: string) {
  return stripTerminalNoise(value)
    .replace(/^[\u2800-\u28ff✳\s]+/u, "")
    .trim();
}

function meaningfulTailLines(tail: string, count = 8) {
  return tail
    .split("\n")
    .map(stripTerminalNoise)
    .map((line) => line.replace(/[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]/g, "").trim())
    .filter((line) => line.length > 0)
    .filter((line) => !/^[╭╮╰╯│─━═—\s]+$/.test(line))
    .filter((line) => !/^--/.test(line))
    .filter((line) => !/^›\s/.test(line))
    .slice(-count);
}

function summarizeRecentWork(tail: string): string {
  const lines = meaningfulTailLines(tail, 32)
    .filter((line, index, all) => index === 0 || line !== all[index - 1])
    .filter((line) => {
      const lower = line.toLowerCase();
      return /succeeded|passed|finished|completed|done|fixed|updated|created|generated|built|compiled|checked|installed|launched|failed|error/.test(lower);
    })
    .slice(-4)
    .map((line) => line.length > 150 ? `${line.slice(0, 147)}...` : line);

  if (lines.length === 0) {
    const recent = meaningfulTailLines(tail, 4)
      .filter((line, index, all) => index === 0 || line !== all[index - 1])
      .map((line) => line.length > 150 ? `${line.slice(0, 147)}...` : line);
    if (recent.length === 0) {
      return "No recent work has been captured yet.";
    }
    return recent.map((line) => `- ${line}`).join("\n");
  }

  return lines.map((line) => `- ${line}`).join("\n");
}

function phaseFeedbackMessage(
  pane: BasePane,
  lines: string[],
  status: PaneStatus,
  reason: string,
  now: string,
  fingerprint: string,
  source: InteractionMessage["source"],
): InteractionMessage {
  const lastLine = lines.at(-1);
  const base = {
    id: `${pane.id}:feedback:${status}:${fingerprint}`,
    paneId: pane.id,
    role: "agent" as const,
    priority: "normal" as const,
    source,
    createdAt: now,
  };

  if (status === "running") {
    return {
      ...base,
      kind: "notification",
      title: "Phase feedback",
      body: lastLine ? `Latest checkpoint: ${lastLine}` : "The agent is still working. Feedback will update when the next checkpoint appears.",
    };
  }

  if (status === "waiting") {
    return {
      ...base,
      kind: "notification",
      priority: "high",
      title: "Blocked",
      body: "The agent is waiting for your reply before it can continue.",
    };
  }

  if (status === "failed") {
    return {
      ...base,
      kind: "notification",
      priority: "high",
      title: "Needs follow-up",
      body: reason || lastLine || "The last phase needs attention before work can continue.",
    };
  }

  if (status === "done") {
    return {
      ...base,
      kind: "notification",
      title: "Ready for next instruction",
      body: "Recent work appears complete. You can send a follow-up instruction below.",
    };
  }

  return {
    ...base,
    kind: "notification",
    priority: "low",
    title: "Ready",
    body: "No active work is running. Send a new instruction below when you want the agent to continue.",
  };
}

function localInteractionMessages(
  pane: BasePane,
  tail: string,
  status: PaneStatus,
  reason: string,
  now: string,
): InteractionMessage[] {
  const lines = meaningfulTailLines(tail, 10);
  const excerpt = lines.slice(-3).join("\n");
  const title = cleanTaskTitle(pane.title);
  const fingerprint = tailHash(activityFingerprint(tail));
  const base = {
    paneId: pane.id,
    role: "agent" as const,
    createdAt: now,
    source: excerpt ? { type: "log" as const, excerpt } : undefined,
  };
  const historyMessage: InteractionMessage = {
    ...base,
    id: `${pane.id}:summary:${fingerprint}`,
    kind: "summary",
    priority: "low",
    title: "Recent work",
    body: summarizeRecentWork(tail),
  };
  const currentBase = {
    ...base,
    id: `${pane.id}:current:${status}:${fingerprint}`,
  };

  if (status === "waiting") {
    const prompt = lines.at(-1) || "I need your input before I can continue.";
    const isPermission = /allow|approve|permission|continue|proceed|yes\/no|\by\/n\b/i.test(prompt);
    return [historyMessage, {
      ...currentBase,
      kind: isPermission ? "permission_request" : "question",
      priority: "high",
      title: isPermission ? "Approval needed" : "Agent is asking",
      body: prompt,
      actions: [
        { label: "Yes", payload: "yes" },
        { label: "No", payload: "no", style: "destructive" },
        { label: "Continue", payload: "继续" },
      ],
    }, phaseFeedbackMessage(pane, lines, status, reason, now, fingerprint, historyMessage.source)];
  }

  if (status === "running") {
    return [historyMessage, {
      ...currentBase,
      kind: "progress",
      priority: "normal",
      title: "Working",
      body: title ? `Working on ${title}.` : reason || "Working on the current task.",
    }, phaseFeedbackMessage(pane, lines, status, reason, now, fingerprint, historyMessage.source)];
  }

  if (status === "failed") {
    return [historyMessage, {
      ...currentBase,
      kind: "error",
      priority: "high",
      title: "Needs attention",
      body: reason || lines.at(-1) || "The agent appears to have hit an error.",
      actions: [{ label: "Open log", payload: "open_terminal" }],
    }, phaseFeedbackMessage(pane, lines, status, reason, now, fingerprint, historyMessage.source)];
  }

  if (status === "done") {
    return [historyMessage, {
      ...currentBase,
      kind: "done",
      priority: "normal",
      title: "Completed",
      body: title ? `Finished ${title}.` : reason || "Task completed.",
    }, phaseFeedbackMessage(pane, lines, status, reason, now, fingerprint, historyMessage.source)];
  }

  return [historyMessage, {
    ...currentBase,
    kind: "status",
    priority: "low",
    title: "Idle",
    body: reason || "The agent is idle right now.",
  }, phaseFeedbackMessage(pane, lines, status, reason, now, fingerprint, historyMessage.source)];
}

function normalizeInteractionMessage(
  value: unknown,
  paneId: string,
  now: string,
  fallback: InteractionMessage,
): InteractionMessage | null {
  if (!value || typeof value !== "object") return null;
  const item = value as Record<string, unknown>;
  const role = item.role === "user" || item.role === "system" ? item.role : "agent";
  const kinds = new Set<InteractionMessageKind>(["summary", "status", "question", "permission_request", "progress", "error", "done", "notification"]);
  const kind = typeof item.kind === "string" && kinds.has(item.kind as InteractionMessageKind)
    ? item.kind as InteractionMessageKind
    : fallback.kind;
  const priority = item.priority === "low" || item.priority === "high" ? item.priority : "normal";
  const title = typeof item.title === "string" && item.title.trim() ? item.title.trim().slice(0, 80) : fallback.title;
  const body = typeof item.body === "string" && item.body.trim() ? item.body.trim().slice(0, 800) : fallback.body;
  const actions = Array.isArray(item.actions)
    ? item.actions
        .map((action) => {
          if (!action || typeof action !== "object") return null;
          const candidate = action as Record<string, unknown>;
          if (typeof candidate.label !== "string" || typeof candidate.payload !== "string") return null;
          return {
            label: candidate.label.slice(0, 32),
            payload: candidate.payload.slice(0, 120),
            style: candidate.style === "destructive" ? "destructive" as const : "default" as const,
          };
        })
        .filter((action): action is NonNullable<typeof action> => Boolean(action))
        .slice(0, 4)
    : fallback.actions;

  return {
    id: typeof item.id === "string" && item.id ? item.id : `${paneId}:${kind}:${tailHash(`${title}\n${body}`)}`,
    paneId,
    role,
    kind,
    priority,
    title,
    body,
    actions,
    source: fallback.source,
    createdAt: typeof item.createdAt === "string" && item.createdAt ? item.createdAt : now,
  };
}

async function interpretPaneMessagesWithDeepSeek(
  pane: Omit<Pane, "messages">,
  fallbackMessages: InteractionMessage[],
  cacheKey: string,
): Promise<void> {
  if (!deepSeekApiKey || pendingMessageInterpretations.has(cacheKey)) return;
  pendingMessageInterpretations.add(cacheKey);

  try {
    const response = await fetch(`${deepSeekBaseUrl.replace(/\/+$/, "")}/chat/completions`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${deepSeekApiKey}`,
      },
      body: JSON.stringify({
        model: deepSeekModel,
        response_format: { type: "json_object" },
        messages: [
          {
            role: "system",
            content: [
              "You convert terminal logs from coding agents into concise product-facing interaction messages.",
              "Return only JSON with a messages array. Do not include markdown.",
              "Do not expose secrets, tokens, raw stack traces, or long logs.",
              "Return exactly 3 messages in this order: recent work summary, current state, phase feedback.",
              "The first message must be kind summary with title Recent work and must summarize what the agent recently completed or attempted.",
              "The second message should describe current state: Working, Waiting, Completed, Failed, or Idle.",
              "The third message should be phase feedback: newest checkpoint, blocker, completion feedback, or next useful step.",
              "Messages must follow: role agent|system, kind summary|status|question|permission_request|progress|error|done|notification, priority low|normal|high, title, body, actions.",
            ].join("\n"),
          },
          {
            role: "user",
            content: JSON.stringify({
              pane: {
                id: pane.id,
                session: pane.session,
                command: pane.command,
                title: pane.title,
                status: pane.status,
                reason: pane.reason,
              },
              recentLog: meaningfulTailLines(pane.tail, 18).join("\n"),
            }),
          },
        ],
      }),
    });

    if (!response.ok) return;
    const data = await response.json() as { choices?: Array<{ message?: { content?: string } }> };
    const content = data.choices?.[0]?.message?.content;
    if (!content) return;
    const parsed = JSON.parse(content) as { messages?: unknown[] };
    const firstFallback = fallbackMessages[0];
    const messages = Array.isArray(parsed.messages)
      ? parsed.messages
          .map((message, index) => normalizeInteractionMessage(
            message,
            pane.id,
            pane.updatedAt,
            fallbackMessages[Math.min(index, fallbackMessages.length - 1)] ?? firstFallback,
          ))
          .filter((message): message is InteractionMessage => Boolean(message))
          .slice(0, 3)
      : [];
    if (messages.length > 0) {
      messageCache.set(cacheKey, messages);
    }
  } catch {
    // Keep the deterministic fallback. Interpretation must never break monitoring.
  } finally {
    pendingMessageInterpretations.delete(cacheKey);
  }
}

function normalizeRefinedText(original: string, value: unknown): string {
  if (!value || typeof value !== "object") return original;
  const item = value as Record<string, unknown>;
  const candidate = typeof item.text === "string" ? item.text.trim() : "";
  if (!candidate) return original;
  if (candidate.length > 4000) return original;
  return candidate;
}

async function refineTextWithDeepSeek(text: string): Promise<RefinedTextResponse> {
  const original = text.trim();
  if (!original) return { ok: true, text: original, changed: false };
  if (!deepSeekApiKey) {
    return { ok: true, text: original, changed: false, fallback: true, error: "DeepSeek API key is not configured" };
  }

  try {
    const response = await fetch(`${deepSeekBaseUrl.replace(/\/+$/, "")}/chat/completions`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${deepSeekApiKey}`,
      },
      body: JSON.stringify({
        model: deepSeekModel,
        response_format: { type: "json_object" },
        messages: [
          {
            role: "system",
            content: [
              "You clean up speech-to-text drafts before they are sent to a coding agent.",
              "Return only JSON: {\"text\":\"...\"}.",
              "Preserve the user's intent, language, tone, and commands.",
              "Add punctuation and paragraph breaks when useful.",
              "Fix likely technical terms such as Claude Code, Codex, tmux, SwiftUI, Xcode, TestFlight, DeepSeek, API, WebSocket, TypeScript, React, Rust, iOS, macOS, zsh, npm, cargo, xcodebuild.",
              "Do not add new instructions, explanations, markdown, quotes, greetings, or summaries.",
              "If the draft already looks correct, return it unchanged.",
            ].join("\n"),
          },
          {
            role: "user",
            content: JSON.stringify({ text: original }),
          },
        ],
      }),
    });

    if (!response.ok) {
      return { ok: true, text: original, changed: false, fallback: true, error: `DeepSeek HTTP ${response.status}` };
    }

    const data = await response.json() as { choices?: Array<{ message?: { content?: string } }> };
    const content = data.choices?.[0]?.message?.content;
    if (!content) return { ok: true, text: original, changed: false, fallback: true, error: "DeepSeek returned empty content" };
    const refined = normalizeRefinedText(original, JSON.parse(content));
    return { ok: true, text: refined, changed: refined !== original };
  } catch (error) {
    const message = error instanceof Error ? error.message : "DeepSeek refinement failed";
    return { ok: true, text: original, changed: false, fallback: true, error: message };
  }
}

function interactionMessagesForPane(
  pane: BasePane,
  tail: string,
  status: PaneStatus,
  reason: string,
  now: string,
) {
  const fingerprint = tailHash(activityFingerprint(tail));
  const cacheKey = `${pane.id}:${status}:${fingerprint}`;
  const fallbackMessages = localInteractionMessages(pane, tail, status, reason, now);
  const cached = messageCache.get(cacheKey);
  if (!cached) {
    void interpretPaneMessagesWithDeepSeek(
      { ...pane, tail, status, reason, updatedAt: now },
      fallbackMessages,
      cacheKey,
    );
  }
  return cached ?? fallbackMessages;
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

  const nowMs = Date.now();
  const panes = listed.panes.map((pane) => {
    const tail = capturePane(pane.id);
    const changedRecently = trackPaneActivity(pane.id, tail, nowMs);
    const inferred = inferStatus(pane, tail, changedRecently);
    return {
      ...pane,
      tail,
      ...inferred,
      updatedAt: now,
      messages: interactionMessagesForPane(pane, tail, inferred.status, inferred.reason, now),
    };
  });

  return { ok: true, now, panes };
}

function broadcast(snapshot: Snapshot): void {
  for (const client of clients) {
    client.send({ type: "snapshot", snapshot });
  }
}

function addPaneLogRefresher(paneId: string, refresh: () => void): () => void {
  const refreshers = paneLogRefreshers.get(paneId) ?? new Set<() => void>();
  refreshers.add(refresh);
  paneLogRefreshers.set(paneId, refreshers);

  return () => {
    refreshers.delete(refresh);
    if (refreshers.size === 0) {
      paneLogRefreshers.delete(paneId);
    }
  };
}

function requestPaneLogRefresh(paneId: string): void {
  for (const refresh of paneLogRefreshers.get(paneId) ?? []) {
    try {
      refresh();
    } catch (error) {
      console.warn(`[agent-monitor] pane log refresh failed for ${paneId}:`, error);
    }
  }
}

function requestPaneLogRefreshBurst(paneId: string): void {
  const existingTimers = paneLogRefreshBurstTimers.get(paneId);
  if (existingTimers) {
    for (const timer of existingTimers) clearTimeout(timer);
    existingTimers.clear();
  }

  const timers = existingTimers ?? new Set<ReturnType<typeof setTimeout>>();
  paneLogRefreshBurstTimers.set(paneId, timers);

  for (const delay of paneLogRefreshBurstDelaysMs) {
    if (delay === 0) {
      requestPaneLogRefresh(paneId);
      continue;
    }

    const timer = setTimeout(() => {
      timers.delete(timer);
      requestPaneLogRefresh(paneId);
      if (timers.size === 0 && paneLogRefreshBurstTimers.get(paneId) === timers) {
        paneLogRefreshBurstTimers.delete(paneId);
      }
    }, delay);
    timers.add(timer);
  }
}

function paneCommandResponse(paneId: string): {
  ok: true;
  paneId: string;
  tail: string;
  capturedAt: string;
} {
  return {
    ok: true,
    paneId,
    tail: capturePane(paneId, paneCommandTailLineCount),
    capturedAt: new Date().toISOString(),
  };
}

function sleep(milliseconds: number): Promise<void> {
  return new Promise((resolveSleep) => setTimeout(resolveSleep, milliseconds));
}

async function paneCommandResponseAfterCommand(paneId: string, previousTail: string): Promise<{
  ok: true;
  paneId: string;
  tail: string;
  capturedAt: string;
}> {
  let tail = "";
  for (const delay of paneCommandTailSettleDelaysMs) {
    if (delay > 0) {
      await sleep(delay);
    }
    tail = capturePane(paneId, paneCommandTailLineCount);
    if (tail !== previousTail) {
      break;
    }
  }

  requestPaneLogRefresh(paneId);

  return {
    ok: true,
    paneId,
    tail,
    capturedAt: new Date().toISOString(),
  };
}

function refreshSnapshot(): void {
  lastSnapshot = buildSnapshot();
  broadcast(lastSnapshot);
}

function scheduleSnapshotRefreshSoon(): void {
  if (scheduledSnapshotRefreshTimer) return;
  scheduledSnapshotRefreshTimer = setTimeout(() => {
    scheduledSnapshotRefreshTimer = null;
    refreshSnapshot();
  }, 60);
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

function readBinary(req: IncomingMessage, limitBytes: number): Promise<Buffer | null> {
  return new Promise((resolveData) => {
    const chunks: Buffer[] = [];
    let total = 0;
    let settled = false;
    const settle = (value: Buffer | null) => {
      if (settled) return;
      settled = true;
      resolveData(value);
    };

    req.on("data", (chunk: Buffer) => {
      if (settled) return;
      total += chunk.length;
      if (total > limitBytes) {
        req.destroy();
        settle(null);
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => settle(Buffer.concat(chunks)));
    req.on("error", () => settle(null));
  });
}

function detectImageUpload(image: Buffer): { ext: ".jpg" | ".png"; contentType: "image/jpeg" | "image/png" } | null {
  if (image.length >= 3 && image[0] === 0xff && image[1] === 0xd8 && image[2] === 0xff) {
    return { ext: ".jpg", contentType: "image/jpeg" };
  }

  if (
    image.length >= 8 &&
    image[0] === 0x89 &&
    image[1] === 0x50 &&
    image[2] === 0x4e &&
    image[3] === 0x47 &&
    image[4] === 0x0d &&
    image[5] === 0x0a &&
    image[6] === 0x1a &&
    image[7] === 0x0a
  ) {
    return { ext: ".png", contentType: "image/png" };
  }

  return null;
}

async function handleSend(req: IncomingMessage, res: ServerResponse): Promise<void> {
  if (!isAuthed(req)) return sendJson(res, { error: "unauthorized" }, 401);

  const body = await readJson(req) as {
    paneId?: string;
    text?: string;
    enter?: boolean;
    submitKey?: string;
    vimMode?: boolean;
  } | null;

  if (!body?.paneId || typeof body.text !== "string") {
    return sendJson(res, { error: "paneId and text are required" }, 400);
  }

  if (body.text.length > 4000) {
    return sendJson(res, { error: "text is too long" }, 400);
  }

  const requestedSubmitKey = body.submitKey ?? (body.enter !== false ? "Enter" : null);
  if (requestedSubmitKey !== null && requestedSubmitKey !== "Enter" && requestedSubmitKey !== "Tab") {
    return sendJson(res, { error: "invalid submitKey" }, 400);
  }

  const listed = listPanes();
  const pane = listed.ok ? listed.panes.find((item) => item.id === body.paneId) : undefined;
  const submitKey = pane && isCodexPane(pane) ? "Tab" : requestedSubmitKey;
  const previousTail = capturePane(body.paneId, paneCommandTailLineCount);

  if (body.vimMode) {
    const escape = runTmux(["send-keys", "-t", body.paneId, "C-["]);
    if (!escape.ok) return sendJson(res, { error: escape.error }, 500);

    const insert = runTmux(["send-keys", "-t", body.paneId, "i"]);
    if (!insert.ok) return sendJson(res, { error: insert.error }, 500);
  }

  const sendText = pasteText(body.paneId, body.text);
  if (!sendText.ok) return sendJson(res, { error: sendText.error }, 500);

  if (submitKey) {
    const submit = runTmux(["send-keys", "-t", body.paneId, submitKey]);
    if (!submit.ok) return sendJson(res, { error: submit.error }, 500);
  }

  requestPaneLogRefreshBurst(body.paneId);
  scheduleSnapshotRefreshSoon();
  return sendJson(res, await paneCommandResponseAfterCommand(body.paneId, previousTail));
}

async function handleRefineText(req: IncomingMessage, res: ServerResponse): Promise<void> {
  if (!isAuthed(req)) return sendJson(res, { error: "unauthorized" }, 401);

  const body = await readJson(req) as { text?: string } | null;
  if (!body || typeof body.text !== "string") {
    return sendJson(res, { error: "text is required" }, 400);
  }
  if (body.text.length > 4000) {
    return sendJson(res, { error: "text is too long" }, 400);
  }

  return sendJson(res, await refineTextWithDeepSeek(body.text));
}

async function handleUploadImage(req: IncomingMessage, res: ServerResponse): Promise<void> {
  if (!isAuthed(req)) return sendJson(res, { error: "unauthorized" }, 401);

  const image = await readBinary(req, 8 * 1024 * 1024);
  if (!image || image.length === 0) {
    return sendJson(res, { error: "image is required" }, 400);
  }

  const upload = detectImageUpload(image);
  if (!upload) {
    return sendJson(res, { error: "only jpg and png are supported" }, 400);
  }

  const paneId = requestUrl(req).searchParams.get("paneId") ?? "unknown";
  const safePane = basename(paneId).replace(/[^a-zA-Z0-9_.-]+/g, "_");
  const dir = resolve(rootDir, "output", "mobile-uploads");
  await mkdir(dir, { recursive: true });

  const filename = `${new Date().toISOString().replace(/[:.]/g, "-")}-${safePane}${upload.ext}`;
  const filePath = resolve(dir, filename);
  if (!filePath.startsWith(dir)) {
    return sendJson(res, { error: "invalid upload path" }, 400);
  }

  await writeFile(filePath, image);
  console.info(`[agent-monitor] uploaded image for ${paneId}: ${image.length} bytes -> ${filePath}`);
  return sendJson(res, {
    ok: true,
    path: filePath,
    size: image.length,
    contentType: upload.contentType,
  });
}

async function handleKey(req: IncomingMessage, res: ServerResponse): Promise<void> {
  if (!isAuthed(req)) return sendJson(res, { error: "unauthorized" }, 401);

  const url = requestUrl(req);
  const paneId = url.searchParams.get("paneId");
  const key = url.searchParams.get("key");
  const allowed = new Set(["Enter", "Tab", "C-c", "C-d", "C-[", "Escape", "Up", "Down", "BSpace", "C-u", "VimClear", "VimBackspace"]);

  if (!paneId || !key || !allowed.has(key)) {
    return sendJson(res, { error: "invalid paneId or key" }, 400);
  }

  const previousTail = capturePane(paneId, paneCommandTailLineCount);

  if (key === "VimClear") {
    for (const part of ["C-[", "0", "D", "i"]) {
      const result = runTmux(["send-keys", "-t", paneId, part]);
      if (!result.ok) return sendJson(res, { error: result.error }, 500);
    }

    requestPaneLogRefreshBurst(paneId);
    scheduleSnapshotRefreshSoon();
    return sendJson(res, await paneCommandResponseAfterCommand(paneId, previousTail));
  }

  if (key === "VimBackspace") {
    for (const part of ["C-[", "i", "BSpace"]) {
      const result = runTmux(["send-keys", "-t", paneId, part]);
      if (!result.ok) return sendJson(res, { error: result.error }, 500);
    }

    requestPaneLogRefreshBurst(paneId);
    scheduleSnapshotRefreshSoon();
    return sendJson(res, await paneCommandResponseAfterCommand(paneId, previousTail));
  }

  const result = runTmux(["send-keys", "-t", paneId, key]);
  if (!result.ok) return sendJson(res, { error: result.error }, 500);

  requestPaneLogRefreshBurst(paneId);
  scheduleSnapshotRefreshSoon();
  return sendJson(res, await paneCommandResponseAfterCommand(paneId, previousTail));
}

async function handleKillSession(req: IncomingMessage, res: ServerResponse): Promise<void> {
  if (!isAuthed(req)) return sendJson(res, { error: "unauthorized" }, 401);

  const body = await readJson(req) as {
    paneId?: string;
    session?: string;
  } | null;

  if (body?.paneId) {
    console.warn(`[agent-monitor] closing tmux pane ${body.paneId}`);
    const result = runTmux(["kill-pane", "-t", body.paneId]);
    if (!result.ok) return sendJson(res, { error: result.error }, 500);

    refreshSnapshot();
    return sendJson(res, { ok: true });
  }

  if (!body?.session) {
    return sendJson(res, { error: "paneId is required" }, 400);
  }

  console.warn(`[agent-monitor] rejected session-level kill for ${body.session}`);
  return sendJson(res, { error: "session-level kill is disabled; refresh the client and close a pane instead" }, 400);
}

const httpServer = createServer(async (req, res) => {
  const url = requestUrl(req);

  if (url.pathname === "/api/snapshot") {
    if (!isAuthed(req)) return sendJson(res, { error: "unauthorized" }, 401);
    refreshSnapshot();
    return sendJson(res, lastSnapshot);
  }

  if (url.pathname === "/api/pane/context") {
    if (!isAuthed(req)) return sendJson(res, { error: "unauthorized" }, 401);
    const paneId = url.searchParams.get("paneId");
    if (!paneId) return sendJson(res, { error: "paneId is required" }, 400);

    const lines = contextLineCount(url.searchParams.get("lines"));
    const tail = capturePane(paneId, lines);
    return sendJson(res, {
      ok: true,
      paneId,
      lines,
      tail,
      capturedAt: new Date().toISOString(),
    });
  }

  if (url.pathname === "/api/send" && req.method === "POST") {
    return handleSend(req, res);
  }

  if (url.pathname === "/api/refine-text" && req.method === "POST") {
    return handleRefineText(req, res);
  }

  if (url.pathname === "/api/upload-image" && req.method === "POST") {
    return handleUploadImage(req, res);
  }

  if (url.pathname === "/api/key" && req.method === "POST") {
    return handleKey(req, res);
  }

  if (url.pathname === "/api/session/kill" && req.method === "POST") {
    return handleKillSession(req, res);
  }

  return sendJson(res, { error: "not found" }, 404);
});

const snapshotWss = new WebSocketServer({ noServer: true });
const paneLogWss = new WebSocketServer({ noServer: true });
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

paneLogWss.on("connection", (ws, req) => {
  const url = requestUrl(req);
  const paneId = url.searchParams.get("paneId") ?? "";
  const lines = paneLogLineCount(url.searchParams.get("lines"));

  if (!paneId) {
    ws.send(JSON.stringify({ type: "error", error: "paneId is required" }));
    ws.close();
    return;
  }

  const sendTail = () => {
    if (ws.readyState !== WebSocket.OPEN) return;
    ws.send(JSON.stringify({
      type: "paneLog",
      paneId,
      tail: lastTail,
      capturedAt: new Date().toISOString(),
    }));
  };

  let lastTail = "";
  const captureAndSendTail = (force = false) => {
    const nextTail = capturePane(paneId, lines);
    if (!force && nextTail === lastTail) return;
    lastTail = nextTail;
    sendTail();
  };

  captureAndSendTail(true);
  const removeRefresher = addPaneLogRefresher(paneId, () => captureAndSendTail(false));
  const interval = setInterval(() => {
    captureAndSendTail(false);
  }, 350);

  ws.on("message", (message) => {
    const text = typeof message === "string" ? message : message.toString();
    if (text.includes("refresh")) {
      captureAndSendTail(false);
    }
  });

  ws.on("close", () => {
    removeRefresher();
    clearInterval(interval);
  });
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

  if (url.pathname === "/pane-log/ws") {
    paneLogWss.handleUpgrade(req, socket, head, (ws) => {
      paneLogWss.emit("connection", ws, req);
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
  console.log(`API: http://${host}:${port}/api/snapshot`);
  if (token) {
    console.log("Token auth is enabled by AGENT_MONITOR_TOKEN.");
  } else {
    console.log("Token auth is disabled. Set AGENT_MONITOR_TOKEN to require a token.");
  }
});
