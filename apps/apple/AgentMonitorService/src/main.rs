use std::{
    collections::HashMap,
    env, fs,
    io::{Read, Write},
    net::SocketAddr,
    path::{Component, Path, PathBuf},
    process::Command,
    sync::atomic::{AtomicU64, Ordering},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use axum::{
    body::Body,
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        Query, State,
    },
    http::{header, HeaderMap, Method, Request, Response, StatusCode},
    response::IntoResponse,
    routing::{get, post},
    Json, Router,
};
use futures_util::{SinkExt, StreamExt};
use percent_encoding::percent_decode_str;
use portable_pty::{native_pty_system, CommandBuilder, PtySize};
use serde::{Deserialize, Serialize};
use serde_json::json;
use tokio::sync::{broadcast, mpsc};

const DEFAULT_PORT: u16 = 8787;
const DEFAULT_HOST: &str = "0.0.0.0";
const FIELD_SEPARATOR: &str = "\t";

static BUFFER_COUNTER: AtomicU64 = AtomicU64::new(0);

#[derive(Clone)]
struct AppState {
    token: String,
    public_dir: PathBuf,
    snapshots: broadcast::Sender<serde_json::Value>,
}

#[derive(Debug, Serialize, Clone)]
#[serde(rename_all = "lowercase")]
enum PaneStatus {
    Running,
    Waiting,
    Idle,
    Failed,
    Done,
}

#[derive(Debug, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct Pane {
    id: String,
    target: String,
    session: String,
    window_index: String,
    window_name: String,
    pane_index: String,
    command: String,
    path: String,
    active: bool,
    pid: Option<u32>,
    title: String,
    tail: String,
    status: PaneStatus,
    reason: String,
    updated_at: String,
}

#[derive(Debug, Serialize, Clone)]
struct Snapshot {
    ok: bool,
    now: String,
    panes: Vec<Pane>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

#[derive(Debug)]
struct BasePane {
    id: String,
    target: String,
    session: String,
    window_index: String,
    window_name: String,
    pane_index: String,
    command: String,
    path: String,
    active: bool,
    pid: Option<u32>,
    title: String,
}

#[derive(Debug)]
struct TmuxOutput {
    stdout: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SendRequest {
    pane_id: String,
    text: String,
    enter: Option<bool>,
    vim_mode: Option<bool>,
}

#[derive(Debug, Deserialize)]
struct KillSessionRequest {
    session: String,
}

#[derive(Debug, Deserialize)]
struct TerminalMessage {
    #[serde(rename = "type")]
    message_type: Option<String>,
    data: Option<String>,
    cols: Option<u16>,
    rows: Option<u16>,
}

enum TerminalEvent {
    Data(String),
    Exit,
}

#[tokio::main]
async fn main() {
    let host = env::var("AGENT_MONITOR_HOST").unwrap_or_else(|_| DEFAULT_HOST.to_string());
    let port = env::var("AGENT_MONITOR_PORT")
        .ok()
        .and_then(|value| value.parse::<u16>().ok())
        .unwrap_or(DEFAULT_PORT);
    let token = env::var("AGENT_MONITOR_TOKEN").unwrap_or_default();
    let public_dir = public_dir();
    let public_urls = env::var("AGENT_MONITOR_PUBLIC_URLS").unwrap_or_default();
    let (snapshots, _) = broadcast::channel(32);

    let state = AppState {
        token,
        public_dir,
        snapshots,
    };

    spawn_snapshot_loop(state.clone());

    let app = Router::new()
        .route("/api/snapshot", get(api_snapshot))
        .route("/api/send", post(api_send))
        .route("/api/key", post(api_key))
        .route("/api/session/kill", post(api_kill_session))
        .route("/ws", get(snapshot_ws))
        .route("/terminal/ws", get(terminal_ws))
        .fallback(static_handler)
        .with_state(state.clone());

    let bind_addr = format!("{host}:{port}");
    let listener = tokio::net::TcpListener::bind(&bind_addr)
        .await
        .unwrap_or_else(|error| panic!("failed to bind {bind_addr}: {error}"));
    let addr = listener
        .local_addr()
        .unwrap_or_else(|_| SocketAddr::from(([0, 0, 0, 0], port)));

    println!("Agent Monitor listening on http://{addr}");
    let urls = public_urls
        .split(',')
        .map(str::trim)
        .filter(|item| !item.is_empty())
        .collect::<Vec<_>>();
    if urls.is_empty() {
        println!("Open: http://{host}:{port}/");
    } else {
        println!("Open:");
        for url in urls {
            println!("  {url}/");
        }
    }
    if state.token.is_empty() {
        println!("Token auth is disabled. Set AGENT_MONITOR_TOKEN to require a token.");
    } else {
        println!("Token auth is enabled by AGENT_MONITOR_TOKEN.");
    }

    axum::serve(listener, app).await.expect("server failed");
}

fn public_dir() -> PathBuf {
    if let Ok(path) = env::var("AGENT_MONITOR_PUBLIC_DIR") {
        return PathBuf::from(path);
    }

    env::current_dir()
        .unwrap_or_else(|_| PathBuf::from("."))
        .join("public")
}

fn now_iso() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}

fn run_tmux(args: &[String]) -> Result<TmuxOutput, String> {
    let output = Command::new("tmux")
        .args(args)
        .output()
        .map_err(|error| format!("failed to run tmux: {error}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        let message = if stderr.is_empty() {
            format!("tmux exited with {}", output.status)
        } else {
            stderr
        };
        return Err(message);
    }

    Ok(TmuxOutput {
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
    })
}

fn is_no_tmux_server_error(error: &str) -> bool {
    error.contains("no server running")
}

fn list_panes() -> Result<Vec<BasePane>, String> {
    let format = [
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
    ]
    .join(FIELD_SEPARATOR);

    let result = match run_tmux(&[
        "list-panes".to_string(),
        "-a".to_string(),
        "-F".to_string(),
        format,
    ]) {
        Ok(output) => output,
        Err(error) if is_no_tmux_server_error(&error) => return Ok(Vec::new()),
        Err(error) => return Err(error),
    };

    let panes = result
        .stdout
        .trim()
        .lines()
        .filter(|line| !line.is_empty())
        .map(|line| {
            let mut parts = line.split(FIELD_SEPARATOR);
            let session = parts.next().unwrap_or_default().to_string();
            let window_index = parts.next().unwrap_or_default().to_string();
            let window_name = parts.next().unwrap_or_default().to_string();
            let pane_index = parts.next().unwrap_or_default().to_string();
            let id = parts.next().unwrap_or_default().to_string();
            let command = parts.next().unwrap_or_default().to_string();
            let path = parts.next().unwrap_or_default().to_string();
            let active = parts.next().unwrap_or_default() == "1";
            let pid = parts.next().and_then(|value| value.parse::<u32>().ok());
            let title = parts.next().unwrap_or_default().to_string();
            let target = format!("{session}:{window_index}.{pane_index}");
            let title = if title.is_empty() {
                command.clone()
            } else {
                title
            };

            BasePane {
                id,
                target,
                session,
                window_index,
                window_name,
                pane_index,
                command,
                path,
                active,
                pid,
                title,
            }
        })
        .collect();

    Ok(panes)
}

fn capture_pane(pane_id: &str) -> String {
    run_tmux(&[
        "capture-pane".to_string(),
        "-p".to_string(),
        "-J".to_string(),
        "-S".to_string(),
        "-300".to_string(),
        "-t".to_string(),
        pane_id.to_string(),
    ])
    .map(|output| output.stdout.trim_end().to_string())
    .unwrap_or_default()
}

fn paste_text(pane_id: &str, text: &str) -> Result<(), String> {
    let counter = BUFFER_COUNTER.fetch_add(1, Ordering::Relaxed);
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    let buffer_name = format!("agent-monitor-{timestamp}-{counter}");

    run_tmux(&[
        "set-buffer".to_string(),
        "-b".to_string(),
        buffer_name.clone(),
        "--".to_string(),
        text.to_string(),
    ])?;

    let paste = run_tmux(&[
        "paste-buffer".to_string(),
        "-d".to_string(),
        "-p".to_string(),
        "-b".to_string(),
        buffer_name.clone(),
        "-t".to_string(),
        pane_id.to_string(),
    ]);

    if paste.is_err() {
        let _ = run_tmux(&["delete-buffer".to_string(), "-b".to_string(), buffer_name]);
    }

    paste.map(|_| ())
}

fn infer_status(pane: &BasePane, tail: &str) -> (PaneStatus, String) {
    let lower = tail.to_lowercase();
    let recent = tail
        .lines()
        .rev()
        .take(18)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect::<Vec<_>>()
        .join("\n")
        .to_lowercase();

    if contains_any(
        &recent,
        &[
            "failed",
            "error:",
            "panic:",
            "exception",
            "traceback",
            "exited 1",
            "exited 2",
            "exited 101",
            "exited 127",
            "exited 128",
            "exit 1",
            "exit 2",
            "exit 101",
            "exit 127",
            "exit 128",
        ],
    ) {
        return (
            PaneStatus::Failed,
            "recent output looks like a failure".to_string(),
        );
    }

    if contains_any(
        &recent,
        &[
            "do you want",
            "proceed?",
            "continue?",
            "confirm",
            "yes/no",
            "y/n",
            "(y/n)",
            "allow?",
            "approve",
        ],
    ) {
        return (PaneStatus::Waiting, "looks like it needs input".to_string());
    }

    if contains_any(
        &recent,
        &[
            "success",
            "completed",
            "done",
            "finished",
            "tests passed",
            "all checks passed",
        ],
    ) {
        return (PaneStatus::Done, "recent output looks complete".to_string());
    }

    if [
        "claude", "codex", "node", "bun", "npm", "pnpm", "yarn", "zig", "cargo", "python",
    ]
    .contains(&pane.command.as_str())
    {
        return (PaneStatus::Running, format!("{} is active", pane.command));
    }

    if lower.is_empty() || ["zsh", "bash", "fish", "nu"].contains(&pane.command.as_str()) {
        return (PaneStatus::Idle, "shell pane".to_string());
    }

    (
        PaneStatus::Running,
        format!(
            "{} is active",
            if pane.command.is_empty() {
                "process"
            } else {
                &pane.command
            }
        ),
    )
}

fn contains_any(value: &str, needles: &[&str]) -> bool {
    needles.iter().any(|needle| value.contains(needle))
}

fn build_snapshot() -> Snapshot {
    let now = now_iso();
    let panes = match list_panes() {
        Ok(panes) => panes,
        Err(error) => {
            return Snapshot {
                ok: false,
                now,
                panes: Vec::new(),
                error: Some(error),
            };
        }
    };

    let panes = panes
        .into_iter()
        .map(|pane| {
            let tail = capture_pane(&pane.id);
            let (status, reason) = infer_status(&pane, &tail);

            Pane {
                id: pane.id,
                target: pane.target,
                session: pane.session,
                window_index: pane.window_index,
                window_name: pane.window_name,
                pane_index: pane.pane_index,
                command: pane.command,
                path: pane.path,
                active: pane.active,
                pid: pane.pid,
                title: pane.title,
                tail,
                status,
                reason,
                updated_at: now.clone(),
            }
        })
        .collect();

    Snapshot {
        ok: true,
        now,
        panes,
        error: None,
    }
}

fn broadcast_snapshot(state: &AppState) -> Snapshot {
    let snapshot = build_snapshot();
    let _ = state.snapshots.send(json!({
        "type": "snapshot",
        "snapshot": snapshot,
    }));
    snapshot
}

fn spawn_snapshot_loop(state: AppState) {
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_millis(2500));
        loop {
            interval.tick().await;
            let _ = broadcast_snapshot(&state);
        }
    });
}

fn is_authed(state: &AppState, headers: &HeaderMap, query: &HashMap<String, String>) -> bool {
    if state.token.is_empty() {
        return true;
    }

    let bearer = format!("Bearer {}", state.token);
    query.get("token") == Some(&state.token)
        || headers
            .get(header::AUTHORIZATION)
            .and_then(|value| value.to_str().ok())
            == Some(bearer.as_str())
}

fn json_response<T: Serialize>(status: StatusCode, value: T) -> Response<Body> {
    let body = serde_json::to_vec(&value).unwrap_or_else(|_| b"{\"error\":\"json\"}".to_vec());
    Response::builder()
        .status(status)
        .header(header::CONTENT_TYPE, "application/json; charset=utf-8")
        .body(Body::from(body))
        .expect("response builder")
}

async fn api_snapshot(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<HashMap<String, String>>,
) -> Response<Body> {
    if !is_authed(&state, &headers, &query) {
        return json_response(StatusCode::UNAUTHORIZED, json!({ "error": "unauthorized" }));
    }

    json_response(StatusCode::OK, broadcast_snapshot(&state))
}

async fn api_send(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<HashMap<String, String>>,
    Json(body): Json<SendRequest>,
) -> Response<Body> {
    if !is_authed(&state, &headers, &query) {
        return json_response(StatusCode::UNAUTHORIZED, json!({ "error": "unauthorized" }));
    }

    if body.pane_id.is_empty() {
        return json_response(
            StatusCode::BAD_REQUEST,
            json!({ "error": "paneId and text are required" }),
        );
    }

    if body.text.len() > 4000 {
        return json_response(
            StatusCode::BAD_REQUEST,
            json!({ "error": "text is too long" }),
        );
    }

    if body.vim_mode.unwrap_or(false) {
        if let Err(error) = send_key_parts(&body.pane_id, &["C-[", "i"]) {
            return json_response(StatusCode::INTERNAL_SERVER_ERROR, json!({ "error": error }));
        }
    }

    if let Err(error) = paste_text(&body.pane_id, &body.text) {
        return json_response(StatusCode::INTERNAL_SERVER_ERROR, json!({ "error": error }));
    }

    if body.enter != Some(false) {
        if let Err(error) = send_key_parts(&body.pane_id, &["Enter"]) {
            return json_response(StatusCode::INTERNAL_SERVER_ERROR, json!({ "error": error }));
        }
    }

    broadcast_snapshot(&state);
    json_response(StatusCode::OK, json!({ "ok": true }))
}

async fn api_key(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<HashMap<String, String>>,
) -> Response<Body> {
    if !is_authed(&state, &headers, &query) {
        return json_response(StatusCode::UNAUTHORIZED, json!({ "error": "unauthorized" }));
    }

    let pane_id = query.get("paneId").cloned().unwrap_or_default();
    let key = query.get("key").cloned().unwrap_or_default();
    let allowed = [
        "Enter",
        "C-c",
        "C-d",
        "C-[",
        "Escape",
        "Up",
        "Down",
        "BSpace",
        "C-u",
        "VimClear",
        "VimBackspace",
    ];

    if pane_id.is_empty() || !allowed.contains(&key.as_str()) {
        return json_response(
            StatusCode::BAD_REQUEST,
            json!({ "error": "invalid paneId or key" }),
        );
    }

    let result = match key.as_str() {
        "VimClear" => send_key_parts(&pane_id, &["C-[", "0", "D", "i"]),
        "VimBackspace" => send_key_parts(&pane_id, &["C-[", "i", "BSpace"]),
        _ => send_key_parts(&pane_id, &[key.as_str()]),
    };

    if let Err(error) = result {
        return json_response(StatusCode::INTERNAL_SERVER_ERROR, json!({ "error": error }));
    }

    broadcast_snapshot(&state);
    json_response(StatusCode::OK, json!({ "ok": true }))
}

fn send_key_parts(pane_id: &str, parts: &[&str]) -> Result<(), String> {
    for part in parts {
        run_tmux(&[
            "send-keys".to_string(),
            "-t".to_string(),
            pane_id.to_string(),
            (*part).to_string(),
        ])?;
    }

    Ok(())
}

async fn api_kill_session(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<HashMap<String, String>>,
    Json(body): Json<KillSessionRequest>,
) -> Response<Body> {
    if !is_authed(&state, &headers, &query) {
        return json_response(StatusCode::UNAUTHORIZED, json!({ "error": "unauthorized" }));
    }

    if body.session.is_empty() {
        return json_response(
            StatusCode::BAD_REQUEST,
            json!({ "error": "session is required" }),
        );
    }

    if let Err(error) = run_tmux(&["kill-session".to_string(), "-t".to_string(), body.session]) {
        return json_response(StatusCode::INTERNAL_SERVER_ERROR, json!({ "error": error }));
    }

    broadcast_snapshot(&state);
    json_response(StatusCode::OK, json!({ "ok": true }))
}

async fn snapshot_ws(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<HashMap<String, String>>,
    ws: WebSocketUpgrade,
) -> impl IntoResponse {
    if !is_authed(&state, &headers, &query) {
        return StatusCode::UNAUTHORIZED.into_response();
    }

    ws.on_upgrade(move |socket| async move {
        handle_snapshot_socket(socket, state).await;
    })
    .into_response()
}

async fn handle_snapshot_socket(socket: WebSocket, state: AppState) {
    let (mut sender, mut receiver) = socket.split();
    let hello = json!({
        "type": "hello",
        "snapshot": build_snapshot(),
    });
    if sender
        .send(Message::Text(hello.to_string().into()))
        .await
        .is_err()
    {
        return;
    }

    let mut snapshots = state.snapshots.subscribe();
    loop {
        tokio::select! {
            message = snapshots.recv() => {
                let Ok(message) = message else { break };
                if sender.send(Message::Text(message.to_string().into())).await.is_err() {
                    break;
                }
            }
            incoming = receiver.next() => {
                if incoming.is_none() {
                    break;
                }
            }
        }
    }
}

async fn terminal_ws(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<HashMap<String, String>>,
    ws: WebSocketUpgrade,
) -> impl IntoResponse {
    if !is_authed(&state, &headers, &query) {
        return StatusCode::UNAUTHORIZED.into_response();
    }

    ws.on_upgrade(move |socket| async move {
        handle_terminal_socket(socket, query).await;
    })
    .into_response()
}

async fn handle_terminal_socket(mut socket: WebSocket, query: HashMap<String, String>) {
    let pane_id = query.get("paneId").cloned().unwrap_or_default();
    let requested_cols = query
        .get("cols")
        .and_then(|value| value.parse::<u16>().ok())
        .unwrap_or(96);
    let requested_rows = query
        .get("rows")
        .and_then(|value| value.parse::<u16>().ok())
        .unwrap_or(28);

    let snapshot = build_snapshot();
    let Some(pane) = snapshot
        .panes
        .iter()
        .find(|pane| pane.id == pane_id)
        .cloned()
    else {
        let _ = socket
            .send(Message::Text(
                json!({ "type": "error", "error": "pane not found" })
                    .to_string()
                    .into(),
            ))
            .await;
        let _ = socket.close().await;
        return;
    };

    let _ = run_tmux(&[
        "select-window".to_string(),
        "-t".to_string(),
        format!("{}:{}", pane.session, pane.window_index),
    ]);
    let _ = run_tmux(&["select-pane".to_string(), "-t".to_string(), pane.id.clone()]);

    let pty_system = native_pty_system();
    let pair = match pty_system.openpty(PtySize {
        rows: requested_rows.clamp(8, 80),
        cols: requested_cols.clamp(20, 240),
        pixel_width: 0,
        pixel_height: 0,
    }) {
        Ok(pair) => pair,
        Err(error) => {
            send_terminal_error(&mut socket, format!("failed to open pty: {error}")).await;
            return;
        }
    };

    let mut command = CommandBuilder::new("tmux");
    command.arg("attach-session");
    command.arg("-t");
    command.arg(&pane.session);
    if !pane.path.is_empty() {
        command.cwd(&pane.path);
    }
    command.env("TERM", "xterm-256color");

    let mut child = match pair.slave.spawn_command(command) {
        Ok(child) => child,
        Err(error) => {
            send_terminal_error(&mut socket, format!("failed to attach tmux: {error}")).await;
            return;
        }
    };
    drop(pair.slave);

    let mut reader = match pair.master.try_clone_reader() {
        Ok(reader) => reader,
        Err(error) => {
            let _ = child.kill();
            send_terminal_error(&mut socket, format!("failed to read pty: {error}")).await;
            return;
        }
    };

    let mut writer = match pair.master.take_writer() {
        Ok(writer) => writer,
        Err(error) => {
            let _ = child.kill();
            send_terminal_error(&mut socket, format!("failed to write pty: {error}")).await;
            return;
        }
    };

    let (event_tx, mut event_rx) = mpsc::channel::<TerminalEvent>(128);
    std::thread::spawn(move || {
        let mut buffer = [0_u8; 8192];
        loop {
            match reader.read(&mut buffer) {
                Ok(0) => {
                    let _ = event_tx.blocking_send(TerminalEvent::Exit);
                    break;
                }
                Ok(count) => {
                    let data = String::from_utf8_lossy(&buffer[..count]).into_owned();
                    if event_tx.blocking_send(TerminalEvent::Data(data)).is_err() {
                        break;
                    }
                }
                Err(_) => {
                    let _ = event_tx.blocking_send(TerminalEvent::Exit);
                    break;
                }
            }
        }
    });

    loop {
        tokio::select! {
            event = event_rx.recv() => {
                match event {
                    Some(TerminalEvent::Data(first)) => {
                        let data = collect_terminal_output(first, &mut event_rx).await;
                        if socket.send(Message::Text(json!({ "type": "data", "data": data }).to_string().into())).await.is_err() {
                            break;
                        }
                    }
                    Some(TerminalEvent::Exit) | None => {
                        let _ = socket.send(Message::Text(json!({ "type": "exit", "exitCode": 0, "signal": null }).to_string().into())).await;
                        break;
                    }
                }
            }
            incoming = socket.next() => {
                let Some(Ok(message)) = incoming else { break };
                match message {
                    Message::Text(text) => {
                        if let Ok(message) = serde_json::from_str::<TerminalMessage>(&text) {
                            handle_terminal_message(message, &pair.master, &mut writer);
                        }
                    }
                    Message::Binary(bytes) => {
                        if let Ok(text) = String::from_utf8(bytes.to_vec()) {
                            if let Ok(message) = serde_json::from_str::<TerminalMessage>(&text) {
                                handle_terminal_message(message, &pair.master, &mut writer);
                            }
                        }
                    }
                    Message::Close(_) => break,
                    _ => {}
                }
            }
        }
    }

    let _ = child.kill();
}

async fn collect_terminal_output(
    first: String,
    event_rx: &mut mpsc::Receiver<TerminalEvent>,
) -> String {
    let mut output = first;
    let delay = tokio::time::sleep(Duration::from_millis(16));
    tokio::pin!(delay);

    loop {
        tokio::select! {
            _ = &mut delay => break,
            event = event_rx.recv(), if output.len() < 32_000 => {
                match event {
                    Some(TerminalEvent::Data(data)) => output.push_str(&data),
                    Some(TerminalEvent::Exit) | None => break,
                }
            }
        }
    }

    output
}

fn handle_terminal_message(
    message: TerminalMessage,
    master: &Box<dyn portable_pty::MasterPty + Send>,
    writer: &mut Box<dyn Write + Send>,
) {
    match message.message_type.as_deref() {
        Some("input") => {
            if let Some(data) = message.data {
                let _ = writer.write_all(data.as_bytes());
                let _ = writer.flush();
            }
        }
        Some("resize") => {
            if let (Some(cols), Some(rows)) = (message.cols, message.rows) {
                let _ = master.resize(PtySize {
                    cols: cols.clamp(20, 240),
                    rows: rows.clamp(8, 80),
                    pixel_width: 0,
                    pixel_height: 0,
                });
            }
        }
        _ => {}
    }
}

async fn send_terminal_error(socket: &mut WebSocket, error: String) {
    let _ = socket
        .send(Message::Text(
            json!({ "type": "error", "error": error })
                .to_string()
                .into(),
        ))
        .await;
    let _ = socket.close().await;
}

async fn static_handler(State(state): State<AppState>, request: Request<Body>) -> Response<Body> {
    if request.method() != Method::GET && request.method() != Method::HEAD {
        return Response::builder()
            .status(StatusCode::NOT_FOUND)
            .header(header::CONTENT_TYPE, "text/plain; charset=utf-8")
            .body(Body::from("Not found"))
            .expect("response builder");
    }

    let Some(file_path) = resolve_public_path(&state.public_dir, request.uri().path()) else {
        return Response::builder()
            .status(StatusCode::NOT_FOUND)
            .header(header::CONTENT_TYPE, "text/plain; charset=utf-8")
            .body(Body::from("Not found"))
            .expect("response builder");
    };

    let Ok(metadata) = tokio::fs::metadata(&file_path).await else {
        return Response::builder()
            .status(StatusCode::NOT_FOUND)
            .header(header::CONTENT_TYPE, "text/plain; charset=utf-8")
            .body(Body::from("Not found"))
            .expect("response builder");
    };
    if !metadata.is_file() {
        return Response::builder()
            .status(StatusCode::NOT_FOUND)
            .header(header::CONTENT_TYPE, "text/plain; charset=utf-8")
            .body(Body::from("Not found"))
            .expect("response builder");
    }

    let content_type = mime_guess::from_path(&file_path)
        .first_or_octet_stream()
        .to_string();

    if request.method() == Method::HEAD {
        return Response::builder()
            .status(StatusCode::OK)
            .header(header::CONTENT_TYPE, content_type)
            .header(header::CONTENT_LENGTH, metadata.len())
            .body(Body::empty())
            .expect("response builder");
    }

    match tokio::fs::read(&file_path).await {
        Ok(bytes) => Response::builder()
            .status(StatusCode::OK)
            .header(header::CONTENT_TYPE, content_type)
            .header(header::CONTENT_LENGTH, bytes.len())
            .body(Body::from(bytes))
            .expect("response builder"),
        Err(_) => Response::builder()
            .status(StatusCode::NOT_FOUND)
            .header(header::CONTENT_TYPE, "text/plain; charset=utf-8")
            .body(Body::from("Not found"))
            .expect("response builder"),
    }
}

fn resolve_public_path(public_dir: &Path, uri_path: &str) -> Option<PathBuf> {
    let relative = if uri_path == "/" {
        "index.html".to_string()
    } else {
        percent_decode_str(uri_path.trim_start_matches('/'))
            .decode_utf8()
            .ok()?
            .to_string()
    };

    let mut path = public_dir.to_path_buf();
    for component in Path::new(&relative).components() {
        match component {
            Component::Normal(part) => path.push(part),
            _ => return None,
        }
    }

    let canonical_public = fs::canonicalize(public_dir).ok()?;
    let parent = path.parent().unwrap_or(public_dir);
    let canonical_parent = fs::canonicalize(parent).ok()?;
    if !canonical_parent.starts_with(canonical_public) {
        return None;
    }

    Some(path)
}
