const token = new URL(location.href).searchParams.get("token") ?? localStorage.getItem("agent-monitor-token") ?? "";
if (token) localStorage.setItem("agent-monitor-token", token);

const state = {
  snapshot: null,
  selectedPaneId: null,
  statusFilter: "all",
};

const $ = (selector) => document.querySelector(selector);
const panesEl = $("#panes");
const summaryEl = $("#summary");
const connectionEl = $("#connection");
const refreshButton = $("#refreshButton");
const wakeLockButton = $("#wakeLockButton");
const lastUpdatedEl = $("#lastUpdated");
const dialog = $("#detailDialog");
const detailTarget = $("#detailTarget");
const detailTitle = $("#detailTitle");
const detailMeta = $("#detailMeta");
const detailTail = $("#detailTail");
const sendText = $("#sendText");
const sendButton = $("#sendButton");
const killSessionButton = $("#killSessionButton");
const vimModeToggle = $("#vimModeToggle");
const statusTab = $("#statusTab");
const terminalTab = $("#terminalTab");
const statusPanel = $("#statusPanel");
const terminalPanel = $("#terminalPanel");
const terminalMount = $("#terminalMount");
const terminalConnectButton = $("#terminalConnectButton");
const terminalDisconnectButton = $("#terminalDisconnectButton");
const terminalStatus = $("#terminalStatus");

vimModeToggle.checked = localStorage.getItem("agent-monitor-vim-mode") === "1";

const terminalState = {
  term: null,
  fit: null,
  ws: null,
  paneId: null,
  fitFrame: null,
  pendingOutput: "",
  writeFrame: null,
};

const statusLabels = {
  all: "All",
  running: "Running",
  waiting: "Waiting",
  idle: "Idle",
  failed: "Failed",
  done: "Done",
};

const terminalKeyMap = {
  esc: "\x1b",
  tab: "\t",
  enter: "\r",
  "ctrl-c": "\x03",
  "ctrl-d": "\x04",
  "ctrl-u": "\x15",
  backspace: "\x7f",
  left: "\x1b[D",
  right: "\x1b[C",
  up: "\x1b[A",
  down: "\x1b[B",
};

let wakeLock = null;

function authQuery() {
  return token ? `?token=${encodeURIComponent(token)}` : "";
}

function setConnection(text, tone = "") {
  connectionEl.textContent = text;
  connectionEl.dataset.tone = tone;
}

function groupCounts(panes) {
  return panes.reduce((acc, pane) => {
    acc[pane.status] = (acc[pane.status] ?? 0) + 1;
    return acc;
  }, {});
}

function renderSummary(snapshot) {
  if (!snapshot?.ok) {
    summaryEl.innerHTML = `<article class="notice"><strong>tmux unavailable</strong><span>${escapeHtml(snapshot?.error ?? "No data")}</span></article>`;
    lastUpdatedEl.textContent = "snapshot unavailable";
    return;
  }

  const scopedPanes = agentScopedPanes(snapshot.panes);
  const counts = groupCounts(scopedPanes);
  const entries = ["all", "waiting", "running", "failed", "done", "idle"];
  lastUpdatedEl.textContent = `updated ${formatTime(snapshot.now)} · ${scopedPanes.length} agents · ${snapshot.panes.length} panes`;
  summaryEl.innerHTML = entries.map((key) => `
    <button class="stat" data-filter="${key}" data-status="${key}" aria-pressed="${state.statusFilter === key}">
      <span>${statusLabels[key]}</span>
      <strong>${key === "all" ? scopedPanes.length : counts[key] ?? 0}</strong>
    </button>
  `).join("");

  for (const stat of summaryEl.querySelectorAll("[data-filter]")) {
    stat.addEventListener("click", () => {
      state.statusFilter = stat.dataset.filter;
      render();
    });
  }
}

function renderPanes(snapshot) {
  if (!snapshot?.ok) {
    panesEl.innerHTML = "";
    return;
  }

  const sourcePanes = agentScopedPanes(snapshot.panes);
  const panes = state.statusFilter === "all"
    ? sourcePanes
    : sourcePanes.filter((pane) => pane.status === state.statusFilter);

  if (snapshot.panes.length === 0) {
    panesEl.innerHTML = `<article class="empty">No tmux panes found. Start one with <code>tmux new -s work</code>.</article>`;
    return;
  }

  if (panes.length === 0) {
    panesEl.innerHTML = `<article class="empty">No ${escapeHtml(statusLabels[state.statusFilter] ?? state.statusFilter)} panes.</article>`;
    return;
  }

  const groups = [
    ["Working Now", panes.filter((pane) => pane.status === "running" || pane.status === "waiting")],
    ["Completed", panes.filter((pane) => pane.status === "done")],
    ["Other", panes.filter((pane) => !["running", "waiting", "done"].includes(pane.status))],
  ].filter(([, items]) => items.length > 0);

  panesEl.innerHTML = groups.map(([title, items]) => `
    <section class="pane-section">
      <header class="pane-section-header">
        <h2>${escapeHtml(title)}</h2>
        <span>${items.length}</span>
      </header>
      <div class="pane-section-grid">
        ${items.map(renderPaneCard).join("")}
      </div>
    </section>
  `).join("");

  for (const card of panesEl.querySelectorAll(".pane-card")) {
    card.addEventListener("click", () => openPane(card.dataset.paneId));
  }
}

function renderPaneCard(pane) {
  const lastLines = pane.tail.split("\n").slice(-5).join("\n");
  return `
    <button class="pane-card" data-pane-id="${escapeAttr(pane.id)}" data-status="${pane.status}">
      <span class="status-dot"></span>
      <span class="pane-main">
        <span class="pane-row">
          <span class="project-title">${escapeHtml(projectName(pane))}</span>
          <span class="pane-badge">${escapeHtml(statusLabels[pane.status])}</span>
        </span>
        <span class="agent-row">
          <span class="agent-pill">${escapeHtml(agentName(pane))}</span>
          <span>${escapeHtml(pane.session)}</span>
        </span>
        <span class="pane-subtitle">${escapeHtml(pane.command || "shell")} · ${escapeHtml(pane.reason)}</span>
        <code>${escapeHtml(lastLines || pane.path || "No output yet")}</code>
      </span>
    </button>
  `;
}

function isCodingAgentPane(pane) {
  const haystack = `${pane.session}\n${pane.command}\n${pane.title}\n${pane.tail}`.toLowerCase();
  return pane.session.startsWith("cc_")
    || pane.session.startsWith("cx_")
    || haystack.includes("claude")
    || haystack.includes("codex")
    || haystack.includes("gpt-");
}

function agentScopedPanes(panes) {
  const codingPanes = panes.filter(isCodingAgentPane);
  return codingPanes.length > 0 ? codingPanes : panes;
}

function projectName(pane) {
  const pathParts = pane.path.split("/").filter(Boolean);
  const fromPath = pathParts[pathParts.length - 1];
  if (fromPath) return fromPath;

  const sessionParts = pane.session.split("_");
  if (sessionParts.length >= 2) return sessionParts[1];
  return pane.session;
}

function agentName(pane) {
  const haystack = `${pane.session}\n${pane.command}\n${pane.title}\n${pane.tail}`.toLowerCase();
  if (pane.session.startsWith("cc_")) return "Claude Code";
  if (pane.session.startsWith("cx_")) return "Codex";
  if (haystack.includes("claude")) return "Claude Code";
  if (haystack.includes("codex") || haystack.includes("gpt-")) return "Codex";
  return pane.command || "Shell";
}

function render() {
  renderSummary(state.snapshot);
  renderPanes(state.snapshot);
  if (dialog.open && state.selectedPaneId) {
    renderDetail(state.selectedPaneId);
  }
}

function openPane(paneId) {
  state.selectedPaneId = paneId;
  renderDetail(paneId);
  showDetailTab("status");
  dialog.showModal();
  setTimeout(fitTerminal, 0);
}

function renderDetail(paneId) {
  const pane = state.snapshot?.panes.find((item) => item.id === paneId);
  if (!pane) return;

  detailTarget.textContent = pane.target;
  detailTitle.textContent = `${pane.session} · ${pane.command || "shell"}`;
  detailMeta.innerHTML = [
    ["Status", statusLabels[pane.status]],
    ["Path", pane.path],
    ["Pane", pane.id],
    ["PID", pane.pid ?? "-"],
  ].map(([label, value]) => `
    <div>
      <span>${escapeHtml(label)}</span>
      <strong>${escapeHtml(String(value))}</strong>
    </div>
  `).join("");
  detailTail.textContent = pane.tail || "No output yet.";
  detailTail.scrollTop = detailTail.scrollHeight;
}

function showDetailTab(tab) {
  const terminalActive = tab === "terminal";
  statusTab.classList.toggle("active", !terminalActive);
  terminalTab.classList.toggle("active", terminalActive);
  statusPanel.classList.toggle("hidden", terminalActive);
  terminalPanel.classList.toggle("hidden", !terminalActive);

  if (terminalActive) {
    connectTerminal();
    setTimeout(fitTerminal, 0);
  }
}

async function sendToPane() {
  const text = sendText.value;
  if (!state.selectedPaneId || !text.trim()) return;

  sendButton.disabled = true;
  try {
    await fetch("/api/send", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({
        paneId: state.selectedPaneId,
        text,
        enter: true,
        vimMode: vimModeToggle.checked,
      }),
    });
    sendText.value = "";
    await loadSnapshot();
  } finally {
    sendButton.disabled = false;
  }
}

async function sendKey(key) {
  if (!state.selectedPaneId) return;
  await fetch(`/api/key?paneId=${encodeURIComponent(state.selectedPaneId)}&key=${encodeURIComponent(key)}`, {
    method: "POST",
    headers: { authorization: `Bearer ${token}` },
  });
  await loadSnapshot();
}

async function killSelectedSession() {
  const pane = state.snapshot?.panes.find((item) => item.id === state.selectedPaneId);
  if (!pane) return;

  const confirmed = confirm(`Kill tmux session "${pane.session}"?\n\nThis closes every window and pane in that session.`);
  if (!confirmed) return;

  killSessionButton.disabled = true;
  try {
    const response = await fetch("/api/session/kill", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({ session: pane.session }),
    });

    if (!response.ok) {
      const body = await response.json().catch(() => ({ error: "Unknown error" }));
      alert(body.error ?? "Failed to kill session");
      return;
    }

    dialog.close();
    state.selectedPaneId = null;
    await loadSnapshot();
  } finally {
    killSessionButton.disabled = false;
  }
}

function setTerminalStatus(text, tone = "") {
  terminalStatus.textContent = text;
  terminalStatus.dataset.tone = tone;
}

function fitTerminal() {
  if (!terminalState.term || !terminalState.fit || terminalPanel.classList.contains("hidden")) return;
  if (terminalState.fitFrame) return;
  terminalState.fitFrame = requestAnimationFrame(() => {
    terminalState.fitFrame = null;
    terminalState.fit.fit();
    if (terminalState.ws?.readyState === WebSocket.OPEN) {
      terminalState.ws.send(JSON.stringify({
        type: "resize",
        cols: terminalState.term.cols,
        rows: terminalState.term.rows,
      }));
    }
  });
}

function writeTerminal(data) {
  terminalState.pendingOutput += data;
  if (terminalState.writeFrame) return;

  terminalState.writeFrame = requestAnimationFrame(() => {
    terminalState.writeFrame = null;
    if (!terminalState.term || !terminalState.pendingOutput) return;
    const chunk = terminalState.pendingOutput;
    terminalState.pendingOutput = "";
    terminalState.term.write(chunk);
  });
}

function connectTerminal() {
  const pane = state.snapshot?.panes.find((item) => item.id === state.selectedPaneId);
  if (!pane) return;

  if (terminalState.ws && terminalState.paneId === pane.id) {
    return;
  }

  disconnectTerminal();
  terminalMount.textContent = "";

  const mobile = window.matchMedia("(max-width: 720px)").matches;
  const term = new Terminal({
    cursorBlink: !mobile,
    fontFamily: 'ui-monospace, "SF Mono", Menlo, Monaco, Consolas, monospace',
    fontSize: mobile ? 12 : 13,
    lineHeight: 1.12,
    scrollback: mobile ? 800 : 2500,
    fastScrollModifier: "alt",
    fastScrollSensitivity: 5,
    theme: {
      background: "#050605",
      foreground: "#dce4d3",
      cursor: "#9de07b",
      selectionBackground: "#31402d",
    },
  });
  const fit = new FitAddon.FitAddon();
  term.loadAddon(fit);
  term.open(terminalMount);
  fit.fit();
  term.focus();

  const protocol = location.protocol === "https:" ? "wss:" : "ws:";
  const params = new URLSearchParams({
    token,
    paneId: pane.id,
    cols: String(term.cols),
    rows: String(term.rows),
  });
  const ws = new WebSocket(`${protocol}//${location.host}/terminal/ws?${params.toString()}`);

  terminalState.term = term;
  terminalState.fit = fit;
  terminalState.ws = ws;
  terminalState.paneId = pane.id;
  setTerminalStatus("connecting", "warn");

  term.onData((data) => {
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: "input", data }));
    }
  });

  term.onResize(({ cols, rows }) => {
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: "resize", cols, rows }));
    }
  });

  ws.addEventListener("open", () => {
    setTerminalStatus("live", "ok");
    fitTerminal();
    term.focus();
  });

  ws.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    if (message.type === "data") {
      writeTerminal(message.data);
    } else if (message.type === "error") {
      term.writeln(`\r\n[agent-monitor] ${message.error}`);
      setTerminalStatus("error", "bad");
    } else if (message.type === "exit") {
      setTerminalStatus("closed", "warn");
    }
  });

  ws.addEventListener("close", () => {
    setTerminalStatus("closed", "warn");
  });
}

function disconnectTerminal() {
  if (terminalState.fitFrame) cancelAnimationFrame(terminalState.fitFrame);
  if (terminalState.writeFrame) cancelAnimationFrame(terminalState.writeFrame);
  if (terminalState.ws) {
    terminalState.ws.close();
  }
  if (terminalState.term) {
    terminalState.term.dispose();
  }
  terminalState.ws = null;
  terminalState.term = null;
  terminalState.fit = null;
  terminalState.paneId = null;
  terminalState.fitFrame = null;
  terminalState.writeFrame = null;
  terminalState.pendingOutput = "";
  setTerminalStatus("offline");
}

function sendTerminalInput(data) {
  if (terminalState.ws?.readyState === WebSocket.OPEN) {
    terminalState.ws.send(JSON.stringify({ type: "input", data }));
    terminalState.term?.focus();
  }
}

async function loadSnapshot() {
  refreshButton.disabled = true;
  try {
    const response = await fetch(`/api/snapshot${authQuery()}`);
    state.snapshot = await response.json();
    render();
  } finally {
    refreshButton.disabled = false;
  }
}

function connectWebSocket() {
  const protocol = location.protocol === "https:" ? "wss:" : "ws:";
  const ws = new WebSocket(`${protocol}//${location.host}/ws${authQuery()}`);

  ws.addEventListener("open", () => setConnection("live", "ok"));
  ws.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    if (message.snapshot) {
      state.snapshot = message.snapshot;
      render();
    }
  });
  ws.addEventListener("close", () => {
    setConnection("reconnecting", "warn");
    setTimeout(connectWebSocket, 1500);
  });
  ws.addEventListener("error", () => setConnection("offline", "bad"));
}

function escapeHtml(value) {
  return value.replace(/[&<>"']/g, (char) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  })[char]);
}

function escapeAttr(value) {
  return escapeHtml(String(value));
}

function formatTime(value) {
  const date = value ? new Date(value) : new Date();
  return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
}

async function toggleWakeLock() {
  if (!("wakeLock" in navigator)) {
    wakeLockButton.textContent = "No wake lock";
    wakeLockButton.disabled = true;
    return;
  }

  if (wakeLock) {
    await wakeLock.release();
    wakeLock = null;
    wakeLockButton.textContent = "Keep awake";
    wakeLockButton.dataset.active = "0";
    return;
  }

  try {
    wakeLock = await navigator.wakeLock.request("screen");
    wakeLockButton.textContent = "Awake";
    wakeLockButton.dataset.active = "1";
    wakeLock.addEventListener("release", () => {
      wakeLock = null;
      wakeLockButton.textContent = "Keep awake";
      wakeLockButton.dataset.active = "0";
    });
  } catch {
    wakeLockButton.textContent = "Wake blocked";
    wakeLockButton.dataset.active = "0";
  }
}

document.addEventListener("visibilitychange", async () => {
  if (document.visibilityState === "visible" && wakeLockButton.dataset.active === "1" && !wakeLock) {
    await toggleWakeLock();
  }
});

refreshButton.addEventListener("click", () => loadSnapshot().catch(() => setConnection("offline", "bad")));
wakeLockButton.addEventListener("click", toggleWakeLock);
sendButton.addEventListener("click", sendToPane);
killSessionButton.addEventListener("click", killSelectedSession);
statusTab.addEventListener("click", () => showDetailTab("status"));
terminalTab.addEventListener("click", () => showDetailTab("terminal"));
terminalConnectButton.addEventListener("click", connectTerminal);
terminalDisconnectButton.addEventListener("click", disconnectTerminal);
vimModeToggle.addEventListener("change", () => {
  localStorage.setItem("agent-monitor-vim-mode", vimModeToggle.checked ? "1" : "0");
});
for (const button of document.querySelectorAll("[data-key]")) {
  button.addEventListener("click", () => {
    const key = vimModeToggle.checked && button.dataset.vimKey ? button.dataset.vimKey : button.dataset.key;
    sendKey(key);
  });
}
for (const button of document.querySelectorAll("[data-terminal-key]")) {
  button.addEventListener("click", () => sendTerminalInput(terminalKeyMap[button.dataset.terminalKey]));
}

dialog.addEventListener("close", disconnectTerminal);
window.addEventListener("resize", fitTerminal);
window.visualViewport?.addEventListener("resize", fitTerminal);

loadSnapshot().catch(() => setConnection("unauthorized", "bad"));
connectWebSocket();
