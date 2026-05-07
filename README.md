# Agent Monitor

Mobile-friendly monitor and control surface for agent sessions running inside tmux.

Agent Monitor is local-first. It is meant for localhost, a trusted LAN, or a private Tailscale tailnet. By default it does not require a token.

## Requirements

- macOS or Linux with tmux
- Node.js 20+
- npm

## Repository Layout

```txt
.
├── src/                 # Node reference service
├── web/                 # Vite + React mobile dashboard
├── public/              # generated web assets
├── scripts/             # LaunchAgent helpers for the Node service
└── apps/apple/          # combined macOS + iOS XcodeGen project
```

## Start

```bash
npm install
cp .env.example .env
npm run build:web
npm run start
```

Open the printed URL on the same machine. For phone access, expose it through Tailscale or Cloudflare Tunnel.

```bash
# Optional: require a token if you expose it beyond a trusted LAN.
AGENT_MONITOR_TOKEN=change-me npm run start
```

## Auto Start on macOS

Install the user LaunchAgent:

```bash
./scripts/install-launch-agent.sh
```

The service starts at login, restarts on failure, and reads `.env` from this project.

```bash
launchctl print gui/$(id -u)/dev.hcg.agent-monitor
tail -f ~/Library/Logs/agent-monitor.log
```

Uninstall:

```bash
./scripts/uninstall-launch-agent.sh
```

## Usage

Run Codex, Claude Code, tests, or builds in tmux:

```bash
tmux new -s work
codex
```

Agent Monitor discovers panes with `tmux list-panes`, captures recent output with `tmux capture-pane`, sends lightweight controls through `tmux send-keys`, and exposes full terminal sessions through xterm.js plus a PTY-backed `tmux attach-session`.

If no tmux server is running, the dashboard shows an empty session list. Start a monitored process inside tmux first:

```bash
tmux new -s work
codex
```

## Web UI

The dashboard is a Vite + React app composed with shadcn/ui components. Source lives in `web/`, and `npm run build:web` writes the phone-first dashboard into `public/` so the existing Node service and LaunchAgent can serve it.

For frontend-only iteration:

```bash
npm run dev:web
```

## Environment

- `AGENT_MONITOR_HOST`: bind host, default `0.0.0.0` for LAN access
- `AGENT_MONITOR_PORT`: bind port, default `8787`
- `AGENT_MONITOR_PUBLIC_URLS`: optional comma-separated URLs printed on startup, for example `http://127.0.0.1:8787,http://100.64.0.10:8787`
- `AGENT_MONITOR_TOKEN`: optional access token. If omitted, token auth is disabled for trusted LAN use.

## Scope

This is intentionally small:

- pane dashboard
- mobile-first project cards, manual refresh, and optional screen wake lock
- recent output tail
- simple status inference
- text reply
- quick keys: Enter, Delete, Clear line, Ctrl-C, Ctrl-D, Esc
- Vim mode input: sends `Esc`, enters insert mode, pastes text, then submits
- mobile-friendly full terminal view: xterm.js connects to a PTY-backed `tmux attach-session`
- standalone web app metadata for adding the page to a phone home screen
- kill a stale tmux session after confirmation
- optional token-gated API/WebSocket

It does not persist history or expose a public account system.

## Companion Apps

- `apps/apple`: combined XcodeGen project for the macOS menu bar app and native iOS companion.
- The macOS app includes a Control Center for service status, tmux detection, Tailscale/LAN URLs, diagnostics, and optional `cc`/`cx` wrapper installation.

Useful commands:

```bash
npm run check:rust
npm run build:mac
npm run build:ios
npm run package:mac
```

## Documentation

- [Architecture](./ARCHITECTURE.md)
- [Contributing](./CONTRIBUTING.md)
- [Security](./SECURITY.md)
- [Open source checklist](./OPEN_SOURCE_CHECKLIST.md)
