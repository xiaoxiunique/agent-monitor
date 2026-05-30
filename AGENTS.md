# Repository Guidelines

## Project Structure & Module Organization

`apps/apple/` holds the XcodeGen-based Apple clients: `iOS/` for the phone UI, `Mac/` for the menu bar app, `iOSUITests/` for UI coverage, and `AgentMonitorService/` for the Rust service. `scripts/` contains LaunchAgent install/uninstall helpers for the local Rust service. Top-level docs such as `README.md`, `ARCHITECTURE.md`, and `SECURITY.md` describe behavior, design limits, and security expectations.

## Build, Test, and Development Commands

- `cargo run --manifest-path apps/apple/AgentMonitorService/Cargo.toml`: start the Rust service locally.
- `cargo check --manifest-path apps/apple/AgentMonitorService/Cargo.toml`: validate the Rust service.
- `(cd apps/apple && xcodegen generate && xcodebuild -project AgentMonitorApple.xcodeproj -scheme AgentMonitorMac -destination 'platform=macOS' build)`: build the macOS app.
- `(cd apps/apple && xcodegen generate && pod install && xcodebuild -workspace AgentMonitorApple.xcworkspace -scheme AgentMonitoriOS -destination 'platform=iOS Simulator,name=iPhone 17' build)`: build the iOS app.
- `apps/apple/scripts/package-mac.sh`: create the macOS DMG package.

## Coding Style & Naming Conventions

Match the existing style in each language. Rust service code should stay small, explicit, and formatted with `cargo fmt`. Swift types use `UpperCamelCase`; functions, properties, and local variables use `lowerCamelCase`. Keep generated artifacts out of hand edits when `project.yml` is the source of truth.

## Testing Guidelines

There is no broad unit-test suite yet, so every change should include the narrowest available verification. Run `cargo check --manifest-path apps/apple/AgentMonitorService/Cargo.toml` for service changes and the relevant `xcodebuild` command for Apple app changes. UI behavior that depends on terminal interaction should be covered in `apps/apple/iOSUITests/`, following the existing `*UITests.swift` naming pattern.

## Commit & Pull Request Guidelines

Recent history favors short, imperative commit subjects such as `Fix terminal keyboard dismissal` or `Stabilize terminal scroll UI test`. Keep commits scoped to one change. Pull requests should describe user-visible impact, list verification commands, link related issues, and include screenshots when changing iOS or macOS UI flows.

## Security & Configuration Tips

This project is local-first and intended for trusted LAN or Tailscale setups. Do not commit tokens, Tencent credentials, or `.env` files. If you expose the service beyond a trusted network, keep the optional `AGENT_MONITOR_TOKEN` path working and document the risk in the PR.
