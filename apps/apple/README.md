# Agent Monitor Apple Apps

Swift apps for Agent Monitor live in one XcodeGen project:

- `AgentMonitorMac`: macOS menu bar app that starts the bundled Rust service and serves the web dashboard.
- `AgentMonitoriOS`: iOS companion app for checking recent logs, sending short replies, and opening the terminal view.

The two apps are separate targets in `AgentMonitorApple.xcodeproj`. They share project configuration but do not currently share Swift source modules.

## Requirements

- Xcode
- XcodeGen
- Rust toolchain
- Node.js 20+ at the monorepo root

## Build

From the monorepo root:

```bash
npm run build:mac
npm run build:ios
```

Or from this directory:

```bash
xcodegen generate
xcodebuild -project AgentMonitorApple.xcodeproj -scheme AgentMonitorMac -destination 'platform=macOS' build
xcodebuild -project AgentMonitorApple.xcodeproj -scheme AgentMonitoriOS -destination 'platform=iOS Simulator,name=iPhone 17' build
```

## Package macOS App

From the monorepo root:

```bash
npm run package:mac
```

The package script:

1. Builds the web UI into `public/`.
2. Builds `AgentMonitorService` in release mode.
3. Builds the macOS target.
4. Embeds the Rust service binary and static web assets.
5. Creates `apps/apple/dist/AgentMonitor.dmg`.

The packaged app does not include `node_modules` and does not need Node at runtime.

## macOS Control Center

The macOS app is the local setup and service control surface. Open it from the menu bar:

- `Open Control Center`: shows service, Tailscale/LAN, tmux, and shell command status.
- `Install tmux`: opens Terminal with `brew install tmux` when Homebrew is available.
- `Install cc/cx`: installs wrappers into `~/.agent-monitor/bin` and adds this directory to PATH through a marker block in `~/.zshrc`.
- `Copy Diagnostics`: copies service URLs and local environment status for troubleshooting.

The command wrappers are intentionally conservative:

- They do not overwrite existing aliases or shell functions.
- Conflicting `cc` or `cx` definitions are shown as conflicts in the Control Center.
- Existing shells need `source ~/.zshrc` or a new terminal window after installation.
- `cc` defaults to `claude`.
- `cx` defaults to `codex --yolo`.

You can override the launched commands from your shell:

```bash
export AGENT_MONITOR_CC_COMMAND="claude"
export AGENT_MONITOR_CX_COMMAND="codex --yolo"
```

Each wrapper maps the current directory to a stable tmux session name. Running `cc` or `cx` again from the same directory attaches to the existing session instead of creating a duplicate.

## Runtime Notes

- The macOS app binds `0.0.0.0:8787` and prefers a detected Tailscale IPv4 address for phone access.
- The iOS app defaults to an empty service URL. Configure the Mac service URL in Settings.
- HTTP local networking is allowed because the intended deployment is LAN or Tailscale.
- Public internet exposure should use authentication and TLS.
