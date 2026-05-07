const params = new URLSearchParams(location.search);
const token = params.get("token") ?? localStorage.getItem("agent-monitor-token") ?? "";
const paneId = params.get("paneId") ?? "";

if (token) localStorage.setItem("agent-monitor-token", token);

const mount = document.querySelector("#terminalMount");
const stateEl = document.querySelector("#terminalState");
const reconnectButton = document.querySelector("#reconnectButton");
const keyboardButton = document.querySelector("#keyboardButton");
const fitButton = document.querySelector("#fitButton");

const keyMap = {
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

let term = null;
let fit = null;
let ws = null;
let fitFrame = null;
let pendingOutput = "";
let writeFrame = null;

function setState(text, tone = "") {
  stateEl.textContent = text;
  stateEl.dataset.tone = tone;
}

function focusTerminal() {
  if (!term) return;
  term.focus();
  keyboardButton.dataset.active = "1";
  window.setTimeout(() => {
    keyboardButton.dataset.active = "0";
  }, 700);
}

function fitTerminal() {
  if (!term || !fit) return;
  if (fitFrame) return;
  fitFrame = requestAnimationFrame(() => {
    fitFrame = null;
    fit.fit();
    if (ws?.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: "resize", cols: term.cols, rows: term.rows }));
    }
  });
}

function writeTerminal(data) {
  pendingOutput += data;
  if (writeFrame) return;

  writeFrame = requestAnimationFrame(() => {
    writeFrame = null;
    if (!term || !pendingOutput) return;
    const chunk = pendingOutput;
    pendingOutput = "";
    term.write(chunk);
  });
}

function connect() {
  disconnect();
  mount.textContent = "";

  if (!paneId) {
    setState("missing pane", "bad");
    return;
  }

  const mobile = window.matchMedia("(max-width: 720px)").matches;
  term = new Terminal({
    cursorBlink: !mobile,
    fontFamily: 'ui-monospace, "SF Mono", Menlo, Monaco, Consolas, monospace',
    fontSize: mobile ? 12 : 13,
    lineHeight: 1.12,
    scrollback: mobile ? 800 : 2500,
    disableStdin: false,
    theme: {
      background: "#050605",
      foreground: "#dce4d3",
      cursor: "#9de07b",
      selectionBackground: "#31402d",
    },
  });
  fit = new FitAddon.FitAddon();
  term.loadAddon(fit);
  term.open(mount);
  fit.fit();
  focusTerminal();

  const protocol = location.protocol === "https:" ? "wss:" : "ws:";
  const wsParams = new URLSearchParams({
    token,
    paneId,
    cols: String(term.cols),
    rows: String(term.rows),
  });
  ws = new WebSocket(`${protocol}//${location.host}/terminal/ws?${wsParams.toString()}`);
  setState("connecting", "warn");

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
    setState("live", "ok");
    fitTerminal();
    focusTerminal();
  });

  ws.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    if (message.type === "data") {
      writeTerminal(message.data);
    } else if (message.type === "error") {
      term.writeln(`\r\n[agent-monitor] ${message.error}`);
      setState("error", "bad");
    } else if (message.type === "exit") {
      setState("closed", "warn");
    }
  });

  ws.addEventListener("close", () => setState("closed", "warn"));
  ws.addEventListener("error", () => setState("error", "bad"));
}

function disconnect() {
  if (fitFrame) cancelAnimationFrame(fitFrame);
  if (writeFrame) cancelAnimationFrame(writeFrame);
  fitFrame = null;
  writeFrame = null;
  pendingOutput = "";
  if (ws) ws.close();
  if (term) term.dispose();
  ws = null;
  term = null;
  fit = null;
}

function sendInput(data) {
  if (ws?.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ type: "input", data }));
    focusTerminal();
  }
}

for (const button of document.querySelectorAll("[data-key]")) {
  button.addEventListener("click", () => sendInput(keyMap[button.dataset.key]));
}

reconnectButton.addEventListener("click", connect);
fitButton.addEventListener("click", fitTerminal);
keyboardButton.addEventListener("click", focusTerminal);
mount.addEventListener("pointerdown", focusTerminal, { capture: true });
mount.addEventListener("touchend", focusTerminal, { capture: true });
mount.addEventListener("click", focusTerminal, { capture: true });
window.addEventListener("resize", fitTerminal);
window.visualViewport?.addEventListener("resize", fitTerminal);

connect();
