# Architecture

Agent Monitor is a local-first control surface for agent processes running in tmux.

## Components

- `src/server.ts`: Node.js reference service. It serves the HTTP API, WebSocket streams, and tmux control commands.
- `scripts/`: macOS LaunchAgent helpers for running the Node service at login.
- `apps/apple`: combined XcodeGen project for the macOS menu bar app, iOS companion app, and packaged Rust service.

## Data Flow

1. A user starts `cc`, `cx`, or any long-running task inside tmux.
2. The service polls `tmux list-panes -a` and captures recent output with `tmux capture-pane`.
3. The iOS client reads `GET /api/snapshot` or subscribes to `WS /ws`.
4. Simple replies use `POST /api/send`, which writes through tmux buffers and sends Enter by default.
5. Full terminal mode connects to `WS /terminal/ws`, where the backend attaches to tmux through a PTY.

## API Surface

- `GET /api/snapshot`: current pane list and recent output.
- `POST /api/send`: paste text into a pane, optionally with Vim-mode adaptation.
- `POST /api/key`: send allowed control keys.
- `POST /api/session/kill`: kill a selected tmux session.
- `WS /ws`: live snapshot updates.
- `WS /terminal/ws`: interactive terminal stream.

## Trust Model

The default mode is designed for trusted LAN or Tailscale networks. Token auth is optional and disabled when `AGENT_MONITOR_TOKEN` is unset. Do not expose the service directly to the public internet without an auth layer, TLS, and a clear threat model.

## Apple Project

`apps/apple/project.yml` generates one Xcode project with two app targets:

- `AgentMonitorMac`: packages the Rust backend for a resident macOS menu bar app.
- `AgentMonitoriOS`: native SwiftUI phone client that talks to the same HTTP/WebSocket API.

The Rust backend lives in `apps/apple/AgentMonitorService`. It implements the same API as the Node reference service so the iOS client can use either runtime.

`AgentMonitoriOS` is intentionally configured as an iPhone-only App Store target today. The generated build settings set `TARGETED_DEVICE_FAMILY = 1`, and the shipped `Info.plist` declares portrait orientation only. This avoids App Store Connect's iPad multitasking orientation requirement until the iPad layout is explicitly supported.

The iOS target also includes SwiftTerm for the native terminal view, an asset catalog for AppIcon and launch background color, local-network ATS allowances for LAN/Tailscale HTTP access, microphone privacy descriptions for voice input, and the `audio` background mode for the optional background keep-alive behavior. Tencent Cloud real-time ASR is integrated through CocoaPods (`QCloudRealTime`), so iOS builds use `AgentMonitorApple.xcworkspace`. Apple Speech remains available as a fallback provider.
