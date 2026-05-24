import { open, readdir, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, join } from "node:path";

export type AgentEventKind = "text" | "tool_call" | "tool_result" | "turn" | "status";
export type AgentEventRole = "agent" | "user" | "system";

export type AgentTimelineEvent = {
  id: string;
  paneId: string;
  role: AgentEventRole;
  kind: AgentEventKind;
  title: string;
  body: string;
  createdAt: string;
  toolName?: string;
  callId?: string;
  status?: string;
};

export type AgentEventSource = {
  agent: "claude" | "codex" | "tmux";
  path?: string;
  sessionId?: string;
};

export type AgentPaneRef = {
  id: string;
  session: string;
  command: string;
  title: string;
  path: string;
  tail: string;
};

export type AgentEventsResult = {
  ok: true;
  paneId: string;
  source: AgentEventSource;
  events: AgentTimelineEvent[];
  capturedAt: string;
} | {
  ok: false;
  paneId: string;
  source: AgentEventSource;
  events: AgentTimelineEvent[];
  capturedAt: string;
  error: string;
};

type TranscriptFile = {
  agent: "claude" | "codex";
  path: string;
  sessionId?: string;
  mtimeMs: number;
};

type RawEvent = Omit<AgentTimelineEvent, "id" | "paneId">;

const maxTranscriptReadBytes = 8 * 1024 * 1024;
const maxDiscoveryFiles = 140;
const maxWalkDepth = 7;
const maxBodyCharacters = 1800;
const transcriptLocationCacheTtlMs = 30_000;
const transcriptLocationCache = new Map<string, { foundAt: number; file: TranscriptFile | null }>();

export async function agentEventsForPane(
  pane: AgentPaneRef,
  options: { limit?: number } = {},
): Promise<AgentEventsResult> {
  const capturedAt = new Date().toISOString();
  const limit = clampLimit(options.limit);
  const transcript = await locateTranscriptForPane(pane);

  if (!transcript) {
    return {
      ok: false,
      paneId: pane.id,
      source: { agent: "tmux" },
      events: [],
      capturedAt,
      error: "No matching Claude or Codex transcript was found for this pane.",
    };
  }

  try {
    const text = await readFileTail(transcript.path, maxTranscriptReadBytes);
    const parsed = transcript.agent === "claude"
      ? parseClaudeEvents(text)
      : parseCodexEvents(text);
    const events = finalizeEvents(pane.id, parsed, limit);
    return {
      ok: true,
      paneId: pane.id,
      source: {
        agent: transcript.agent,
        path: transcript.path,
        sessionId: transcript.sessionId,
      },
      events,
      capturedAt,
    };
  } catch (error) {
    return {
      ok: false,
      paneId: pane.id,
      source: {
        agent: transcript.agent,
        path: transcript.path,
        sessionId: transcript.sessionId,
      },
      events: [],
      capturedAt,
      error: error instanceof Error ? error.message : "Failed to parse transcript.",
    };
  }
}

async function locateTranscriptForPane(pane: AgentPaneRef): Promise<TranscriptFile | null> {
  const cacheKey = `${isCodexPaneLike(pane) ? "codex" : "claude"}:${pane.path}`;
  const cached = transcriptLocationCache.get(cacheKey);
  if (cached && Date.now() - cached.foundAt < transcriptLocationCacheTtlMs) {
    return cached.file;
  }

  const preferred: Array<"claude" | "codex"> = isCodexPaneLike(pane)
    ? ["codex", "claude"]
    : ["claude", "codex"];

  for (const agent of preferred) {
    const transcript = agent === "claude"
      ? await locateClaudeTranscript(pane.path)
      : await locateCodexTranscript(pane.path);
    if (transcript) {
      transcriptLocationCache.set(cacheKey, { foundAt: Date.now(), file: transcript });
      return transcript;
    }
  }

  transcriptLocationCache.set(cacheKey, { foundAt: Date.now(), file: null });
  return null;
}

function isCodexPaneLike(pane: Pick<AgentPaneRef, "session" | "command" | "title" | "tail">): boolean {
  const haystack = `${pane.session}\n${pane.command}\n${pane.title}\n${pane.tail}`.toLowerCase();
  return pane.session.startsWith("cx_") || pane.command === "codex" || /\b(codex|gpt-[\w.-]+)/.test(haystack);
}

async function locateClaudeTranscript(cwd: string): Promise<TranscriptFile | null> {
  if (!cwd) return null;

  const roots = uniqueStrings([
    process.env.CLAUDE_PROJECTS_DIR,
    join(homedir(), ".claude", "projects"),
  ].filter((value): value is string => Boolean(value)));
  const projectKey = encodeClaudeProjectPath(cwd);
  const candidates: TranscriptFile[] = [];

  for (const root of roots) {
    const dir = join(root, projectKey);
    let entries: string[] = [];
    try {
      entries = await readdir(dir);
    } catch {
      continue;
    }

    for (const entry of entries) {
      if (!entry.endsWith(".jsonl")) continue;
      const path = join(dir, entry);
      const info = await safeStat(path);
      if (!info?.isFile()) continue;
      candidates.push({
        agent: "claude",
        path,
        sessionId: basename(entry, ".jsonl"),
        mtimeMs: info.mtimeMs,
      });
    }
  }

  return bestTranscriptCandidate(candidates, cwd, scoreClaudeTranscript);
}

async function locateCodexTranscript(cwd: string): Promise<TranscriptFile | null> {
  const roots = uniqueStrings([
    process.env.CODEX_SESSIONS_DIR,
    join(homedir(), ".codex", "sessions"),
    join(homedir(), ".codex", "archived_sessions"),
  ].filter((value): value is string => Boolean(value)));
  const candidates: TranscriptFile[] = [];

  for (const root of roots) {
    const files = await walkJsonlFiles(root, maxWalkDepth);
    for (const path of files) {
      const info = await safeStat(path);
      if (!info?.isFile()) continue;
      candidates.push({
        agent: "codex",
        path,
        sessionId: basename(path, ".jsonl").replace(/^rollout-[^-]+T[^-]+-/, ""),
        mtimeMs: info.mtimeMs,
      });
    }
  }

  return bestTranscriptCandidate(candidates, cwd, scoreCodexTranscript);
}

async function bestTranscriptCandidate(
  candidates: TranscriptFile[],
  cwd: string,
  score: (path: string, cwd: string) => Promise<number>,
): Promise<TranscriptFile | null> {
  const recent = candidates
    .sort((lhs, rhs) => rhs.mtimeMs - lhs.mtimeMs)
    .slice(0, maxDiscoveryFiles);
  let best: { file: TranscriptFile; score: number } | null = null;

  for (const file of recent) {
    const matchScore = await score(file.path, cwd);
    if (matchScore <= 0) continue;
    const recencyScore = Math.max(0, 10_000_000_000 - (Date.now() - file.mtimeMs)) / 10_000_000_000;
    const totalScore = matchScore + recencyScore;
    if (!best || totalScore > best.score) {
      best = { file, score: totalScore };
    }
  }

  return best?.file ?? null;
}

async function scoreClaudeTranscript(path: string, cwd: string): Promise<number> {
  const sample = await readFileTail(path, 512 * 1024);
  if (sample.includes(jsonField("cwd", cwd))) return 100;
  return sample.includes(cwd) ? 50 : 1;
}

async function scoreCodexTranscript(path: string, cwd: string): Promise<number> {
  const sample = await readFileHead(path, 256 * 1024);
  if (sample.includes(jsonField("cwd", cwd))) return 100;
  if (sample.includes(cwd)) return 50;
  return 0;
}

function encodeClaudeProjectPath(cwd: string): string {
  return cwd.replaceAll("/", "-");
}

async function walkJsonlFiles(root: string, maxDepth: number): Promise<string[]> {
  const out: string[] = [];

  async function walk(dir: string, depth: number): Promise<void> {
    if (depth < 0 || out.length >= 2_000) return;
    let entries: Array<{ name: string; isDirectory(): boolean; isFile(): boolean }>;
    try {
      entries = await readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }

    for (const entry of entries) {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) {
        await walk(path, depth - 1);
      } else if (entry.isFile() && entry.name.endsWith(".jsonl")) {
        out.push(path);
      }
    }
  }

  await walk(root, maxDepth);
  return out;
}

async function readFileHead(path: string, maxBytes: number): Promise<string> {
  const handle = await open(path, "r");
  try {
    const info = await handle.stat();
    const length = Math.min(info.size, maxBytes);
    const buffer = Buffer.alloc(length);
    await handle.read(buffer, 0, length, 0);
    return buffer.toString("utf8");
  } finally {
    await handle.close();
  }
}

async function readFileTail(path: string, maxBytes: number): Promise<string> {
  const handle = await open(path, "r");
  try {
    const info = await handle.stat();
    const length = Math.min(info.size, maxBytes);
    const start = Math.max(0, info.size - length);
    const buffer = Buffer.alloc(length);
    await handle.read(buffer, 0, length, start);
    const text = buffer.toString("utf8");
    if (start === 0) return text;
    const newline = text.indexOf("\n");
    return newline >= 0 ? text.slice(newline + 1) : text;
  } finally {
    await handle.close();
  }
}

async function safeStat(path: string) {
  try {
    return await stat(path);
  } catch {
    return null;
  }
}

function parseClaudeEvents(text: string): RawEvent[] {
  const events: RawEvent[] = [];

  for (const item of parseJsonLines(text)) {
    const timestamp = timestampOrNow(item.timestamp);
    const type = stringValue(item.type);
    if (type !== "user" && type !== "assistant") continue;

    const message = objectValue(item.message);
    const role = stringValue(message?.role);
    const content = (message as { content?: unknown } | null)?.content;
    if (role !== "user" && role !== "assistant") continue;

    if (role === "user") {
      const parsed = extractClaudeContent(content);
      if (parsed.text) {
        events.push({
          role: "user",
          kind: "text",
          title: "You",
          body: parsed.text,
          createdAt: timestamp,
        });
      }
      for (const result of parsed.toolResults) {
        events.push({
          role: "agent",
          kind: "tool_result",
          title: result.title,
          body: result.body,
          createdAt: timestamp,
          callId: result.callId,
          status: result.status,
        });
      }
      continue;
    }

    const parsed = extractClaudeContent(content);
    if (parsed.text) {
      events.push({
        role: "agent",
        kind: "text",
        title: "Claude",
        body: parsed.text,
        createdAt: timestamp,
      });
    }
    for (const call of parsed.toolCalls) {
      events.push({
        role: "agent",
        kind: "tool_call",
        title: call.title,
        body: call.body,
        createdAt: timestamp,
        toolName: call.toolName,
        callId: call.callId,
      });
    }
  }

  return events;
}

function parseCodexEvents(text: string): RawEvent[] {
  const events: RawEvent[] = [];

  for (const item of parseJsonLines(text)) {
    const timestamp = timestampOrNow(item.timestamp);
    const type = stringValue(item.type);
    const payload = objectValue(item.payload);
    if (!payload) continue;

    if (type === "event_msg") {
      const eventType = stringValue(payload.type);
      if (eventType === "user_message") {
        const message = cleanBody(stringValue(payload.message));
        if (message && !isSystemishPrompt(message)) {
          events.push({
            role: "user",
            kind: "text",
            title: "You",
            body: message,
            createdAt: timestamp,
          });
        }
      } else if (eventType === "agent_message") {
        const message = cleanBody(stringValue(payload.message));
        if (message) {
          events.push({
            role: "agent",
            kind: "text",
            title: codexPhaseTitle(stringValue(payload.phase)),
            body: message,
            createdAt: timestamp,
          });
        }
      } else if (eventType === "task_started") {
        events.push({
          role: "system",
          kind: "turn",
          title: "Turn started",
          body: "Agent started working on a new instruction.",
          createdAt: timestamp,
          status: "started",
        });
      } else if (eventType === "task_complete") {
        events.push({
          role: "system",
          kind: "turn",
          title: "Turn complete",
          body: formatDuration(Number(payload.duration_ms)),
          createdAt: timestamp,
          status: "complete",
        });
      } else if (eventType === "turn_aborted") {
        events.push({
          role: "system",
          kind: "turn",
          title: "Turn aborted",
          body: "The current turn was interrupted.",
          createdAt: timestamp,
          status: "aborted",
        });
      }
      continue;
    }

    if (type !== "response_item") continue;

    const payloadType = stringValue(payload.type);
    if (payloadType === "function_call") {
      const name = stringValue(payload.name) || "tool";
      const args = parseMaybeJson(stringValue(payload.arguments));
      const formatted = formatToolCall(name, args);
      events.push({
        role: "agent",
        kind: "tool_call",
        title: formatted.title,
        body: formatted.body,
        createdAt: timestamp,
        toolName: name,
        callId: stringValue(payload.call_id),
      });
    } else if (payloadType === "function_call_output") {
      const body = summarizeToolOutput(stringValue(payload.output));
      if (body) {
        events.push({
          role: "agent",
          kind: "tool_result",
          title: "Tool result",
          body,
          createdAt: timestamp,
          callId: stringValue(payload.call_id),
          status: inferToolOutputStatus(body),
        });
      }
    } else if (payloadType === "message") {
      const role = stringValue(payload.role);
      if (role !== "user" && role !== "assistant") continue;
      const message = cleanBody(extractCodexMessageText(payload.content));
      if (!message || isSystemishPrompt(message)) continue;
      events.push({
        role: role === "user" ? "user" : "agent",
        kind: "text",
        title: role === "user" ? "You" : "Codex",
        body: message,
        createdAt: timestamp,
      });
    }
  }

  return events;
}

function extractClaudeContent(content: unknown): {
  text: string;
  toolCalls: Array<{ callId: string; toolName: string; title: string; body: string }>;
  toolResults: Array<{ callId: string; title: string; body: string; status?: string }>;
} {
  if (typeof content === "string") {
    return {
      text: cleanBody(content),
      toolCalls: [],
      toolResults: [],
    };
  }

  if (!Array.isArray(content)) {
    return { text: "", toolCalls: [], toolResults: [] };
  }

  const textParts: string[] = [];
  const toolCalls: Array<{ callId: string; toolName: string; title: string; body: string }> = [];
  const toolResults: Array<{ callId: string; title: string; body: string; status?: string }> = [];

  for (const block of content) {
    const item = objectValue(block);
    if (!item) continue;
    const type = stringValue(item.type);
    if (type === "text") {
      const text = cleanBody(stringValue(item.text));
      if (text) textParts.push(text);
    } else if (type === "tool_use") {
      const name = stringValue(item.name) || "tool";
      const formatted = formatToolCall(name, item.input);
      toolCalls.push({
        callId: stringValue(item.id),
        toolName: name,
        title: formatted.title,
        body: formatted.body,
      });
    } else if (type === "tool_result") {
      const body = summarizeToolOutput(extractClaudeToolResultText(item.content));
      if (body) {
        toolResults.push({
          callId: stringValue(item.tool_use_id),
          title: "Tool result",
          body,
          status: stringValue(item.is_error) === "true" ? "error" : inferToolOutputStatus(body),
        });
      }
    }
  }

  return {
    text: cleanBody(textParts.join("\n\n")),
    toolCalls,
    toolResults,
  };
}

function extractCodexMessageText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  const parts: string[] = [];
  for (const block of content) {
    const item = objectValue(block);
    if (!item) continue;
    const type = stringValue(item.type);
    if (type === "input_text" || type === "output_text" || type === "text") {
      const text = stringValue(item.text);
      if (text) parts.push(text);
    }
  }
  return parts.join("\n\n");
}

function extractClaudeToolResultText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map((block) => {
      const item = objectValue(block);
      return item ? stringValue(item.text) : "";
    })
    .filter(Boolean)
    .join("\n");
}

function formatToolCall(toolName: string, input: unknown): { title: string; body: string } {
  const item = objectValue(input);
  const value = (key: string) => item ? stringValue(item[key]) : "";

  switch (toolName) {
  case "Bash":
  case "bash":
  case "run_command":
  case "exec_command": {
    const command = value("command") || value("cmd");
    const workdir = value("workdir");
    const description = value("description");
    return {
      title: description ? `Run: ${description}` : "Run command",
      body: [workdir ? `cd ${workdir}` : "", command ? `$ ${command}` : compactJson(input)]
        .filter(Boolean)
        .join("\n"),
    };
  }
  case "Read":
  case "read":
  case "read_file":
    return { title: "Read file", body: value("file_path") || value("path") || compactJson(input) };
  case "Edit":
  case "MultiEdit":
  case "Write":
  case "edit":
  case "write":
  case "apply_patch":
    return { title: `${toolName} file`, body: value("file_path") || value("path") || compactJson(input) };
  case "Grep":
  case "grep":
  case "Glob":
  case "glob":
  case "find":
    return { title: toolName, body: value("pattern") || value("query") || value("path") || compactJson(input) };
  case "open":
  case "web.run":
    return { title: "Use web", body: compactJson(input) };
  default:
    return { title: toolName, body: compactJson(input) || "Tool call started." };
  }
}

function summarizeToolOutput(output: string): string {
  const cleaned = cleanBody(output);
  if (!cleaned) return "";

  const marker = "\nOutput:\n";
  const outputIndex = cleaned.lastIndexOf(marker);
  const body = outputIndex >= 0 ? cleaned.slice(outputIndex + marker.length).trim() : cleaned;
  const header = outputIndex >= 0 ? cleaned.slice(0, outputIndex).trim() : "";
  const lines = body.split("\n").filter((line) => line.trim().length > 0);

  if (lines.length === 0) {
    const statusLine = header.split("\n").find((line) => /process exited|process running|wall time/i.test(line));
    return statusLine ? cleanBody(statusLine) : "";
  }

  return truncateText(lines.slice(0, 12).join("\n"), 1200);
}

function inferToolOutputStatus(body: string): string | undefined {
  const lower = body.toLowerCase();
  if (/error|failed|exception|traceback|panic|exited with code [1-9]/.test(lower)) return "error";
  if (/process exited with code 0|succeeded|success|passed/.test(lower)) return "ok";
  return undefined;
}

function codexPhaseTitle(phase: string): string {
  switch (phase) {
  case "commentary":
    return "Update";
  case "final_answer":
    return "Final";
  default:
    return "Codex";
  }
}

function formatDuration(durationMs: number): string {
  if (!Number.isFinite(durationMs) || durationMs <= 0) return "Agent finished this turn.";
  const seconds = Math.round(durationMs / 1000);
  if (seconds < 60) return `Agent finished this turn in ${seconds}s.`;
  return `Agent finished this turn in ${Math.floor(seconds / 60)}m ${seconds % 60}s.`;
}

function finalizeEvents(paneId: string, events: RawEvent[], limit: number): AgentTimelineEvent[] {
  const seen = new Map<string, number>();
  const out: AgentTimelineEvent[] = [];

  events.forEach((event, index) => {
    const body = cleanBody(event.body);
    if (!body) return;
    const title = truncateText(cleanBody(event.title), 80) || defaultTitle(event);
    const dedupeKey = [
      event.role,
      event.kind,
      title,
      normalizeForDedupe(body).slice(0, 500),
    ].join("\u{1f}");
    const previousIndex = seen.get(dedupeKey);
    if (previousIndex !== undefined && index - previousIndex < 8) return;
    seen.set(dedupeKey, index);

    out.push({
      ...event,
      id: `${paneId}:${index}:${hashText(`${event.createdAt}\n${event.role}\n${event.kind}\n${title}\n${body}`)}`,
      paneId,
      title,
      body: truncateText(body, maxBodyCharacters),
    });
  });

  return out.slice(-limit);
}

function defaultTitle(event: RawEvent): string {
  if (event.kind === "tool_call") return event.toolName || "Tool call";
  if (event.kind === "tool_result") return "Tool result";
  if (event.kind === "turn") return "Turn";
  return event.role === "user" ? "You" : "Agent";
}

function parseJsonLines(text: string): Record<string, unknown>[] {
  return text
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => {
      try {
        const value = JSON.parse(line) as unknown;
        return value && typeof value === "object" && !Array.isArray(value)
          ? value as Record<string, unknown>
          : null;
      } catch {
        return null;
      }
    })
    .filter((value): value is Record<string, unknown> => Boolean(value));
}

function parseMaybeJson(value: string): unknown {
  if (!value) return null;
  try {
    return JSON.parse(value) as unknown;
  } catch {
    return value;
  }
}

function objectValue(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

function stringValue(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function timestampOrNow(value: unknown): string {
  if (typeof value === "string" && !Number.isNaN(Date.parse(value))) {
    return value;
  }
  return new Date().toISOString();
}

function cleanBody(value: string): string {
  return value
    .replace(/\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])/g, "")
    .replace(/\r/g, "")
    .trim();
}

function isSystemishPrompt(value: string): boolean {
  const trimmed = value.trim();
  if (trimmed.startsWith("<environment_context>")) return true;
  if (trimmed.startsWith("# AGENTS.md instructions")) return true;
  if (trimmed.includes("<INSTRUCTIONS>") && trimmed.length > 2000) return true;
  if (trimmed.includes("You are Codex") && trimmed.length > 2000) return true;
  return false;
}

function compactJson(value: unknown): string {
  if (typeof value === "string") return truncateText(value, 1000);
  if (!value) return "";
  try {
    return truncateText(JSON.stringify(value, null, 2), 1000);
  } catch {
    return "";
  }
}

function truncateText(value: string, maxLength: number): string {
  if (value.length <= maxLength) return value;
  return `${value.slice(0, maxLength - 1).trimEnd()}...`;
}

function normalizeForDedupe(value: string): string {
  return value.replace(/\s+/g, " ").trim();
}

function clampLimit(value: number | undefined): number {
  if (!Number.isFinite(value)) return 120;
  return Math.max(20, Math.min(300, Math.floor(value ?? 120)));
}

function jsonField(key: string, value: string): string {
  return `"${key}":${JSON.stringify(value)}`;
}

function uniqueStrings(values: string[]): string[] {
  return [...new Set(values)];
}

function hashText(value: string): string {
  let hash = 2166136261;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }
  return (hash >>> 0).toString(16);
}
