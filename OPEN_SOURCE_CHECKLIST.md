# Open Source Checklist

## Ready

- Local-first scope is documented.
- Rust service has install and run instructions.
- macOS LaunchAgent install no longer hardcodes a user-specific path.
- Optional token auth and private-network assumptions are documented.
- API surface and architecture are documented.
- MIT license is added.
- Repository is organized as a monorepo.
- macOS and iOS apps share one Apple XcodeGen project.

## Before Public Release

- Add CI for Rust checks and Swift builds.
- Add release notes and versioning policy.
- Replace personal bundle identifiers if publishing binaries under an organization.
- Decide how signed/notarized macOS releases will be distributed.
- Add screenshots or a short demo GIF.

## Nice To Have

- Configurable default iOS server URL.
- In-app diagnostics page for bound host, port, detected LAN IP, and detected Tailscale IP.
- More explicit error states for tmux missing, no tmux sessions, and connection failures.
- Automated smoke tests for the API with a temporary tmux session.
