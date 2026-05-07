# Security

Agent Monitor is intended for private networks: localhost, LAN, or Tailscale.

## Supported Deployment

- Trusted local machine
- Trusted LAN
- Private Tailscale tailnet

Public internet exposure is not recommended by default.

## Sensitive Capabilities

The service can:

- read recent tmux pane output
- paste text into tmux panes
- send selected control keys
- attach to a tmux session through a terminal WebSocket
- kill tmux sessions after confirmation

This is powerful enough to control shells and developer agents. Treat access to the service like access to your terminal.

## Hardening

- Set `AGENT_MONITOR_TOKEN` when exposing beyond a trusted network.
- Put the service behind HTTPS and an authenticating reverse proxy for any non-private deployment.
- Prefer Tailscale ACLs over public tunnels.
- Keep the port bound to `127.0.0.1` when phone access is not needed.

## Reporting

Do not publish exploitable details before the maintainer has had a chance to respond. Share a minimal reproduction, affected version, and expected impact.
