# Agent Monitor Apple Apps

Swift apps for Agent Monitor live in one XcodeGen project:

- `AgentMonitorMac`: macOS menu bar app that starts the bundled Rust service and exposes setup/status controls.
- `AgentMonitoriOS`: iPhone-first control surface for watching multiple Mac server profiles, reading agent-style project timelines, sending replies or Goal mode prompts, and opening the terminal fallback.

The two apps are separate targets in `AgentMonitorApple.xcodeproj`. They share project configuration but do not currently share Swift source modules.

## Requirements

- Xcode
- XcodeGen
- CocoaPods
- Rust toolchain

## Build

From this directory:

```bash
xcodegen generate
pod install
xcodebuild -project AgentMonitorApple.xcodeproj -scheme AgentMonitorMac -destination 'platform=macOS' build
xcodebuild -workspace AgentMonitorApple.xcworkspace -scheme AgentMonitoriOS -destination 'platform=iOS Simulator,name=iPhone 17' build
```

The iOS target uses CocoaPods for Tencent Cloud real-time ASR. Build and archive iOS from
`AgentMonitorApple.xcworkspace`, not the generated `.xcodeproj`.

## iOS Product Direction

The current iOS app is optimized for being away from the keyboard:

- Machines first: Settings can store multiple server profiles, and the home view summarizes each Mac's connection state, active panes, and sessions needing attention.
- Context handoff: opening a session shows a WeChat-style agent timeline when structured messages are available, while still keeping SwiftTerm terminal access for raw tmux inspection.
- Remote continuation: the composer supports voice/text input, quick controls, image-to-draft upload, and a Goal button that wraps the next message for long-running agent mode.
- Best-effort observation: local notifications are emitted for actionable status changes such as waiting, failed, and done. iOS background execution remains system-limited when the app is off-screen.

## iOS Voice Input

The iOS app supports two voice recognition providers:

- Tencent Cloud real-time ASR via `QCloudRealTime` (default)
- Apple Speech as a fallback provider

Tencent ASR credentials are configured in the iOS Settings screen. The app ships with the
AppID default only; enter `SecretId` and `SecretKey` on device before using Tencent ASR.
Do not commit Tencent `SecretKey` or other long-lived credentials. A server-issued STS
temporary credential flow is the preferred production direction.

## iOS App Store Configuration

`AgentMonitoriOS` is currently an iPhone-only app. Keep the App Store-facing settings in `project.yml`, then regenerate the Xcode project with `xcodegen generate`; direct edits to `AgentMonitorApple.xcodeproj` are generated artifacts and can be overwritten.

Current iOS release constraints:

- Bundle ID: `dev.hcg.AgentMonitor`
- Team ID: `S77C743756`
- Device family: iPhone only, via `TARGETED_DEVICE_FAMILY: "1"`
- Supported orientation: portrait only, via `UISupportedInterfaceOrientations`
- App icon: `iOS/Resources/Assets.xcassets/AppIcon.appiconset`
- Launch background: `iOS/Resources/Assets.xcassets/LaunchBackground.colorset`
- Local networking: ATS allows arbitrary loads because the app talks to the Mac service over LAN or Tailscale HTTP
- Privacy strings: local network, microphone, and speech recognition usage descriptions are required for the current iOS feature set

If the app is changed back to iPhone + iPad, App Store Connect requires the full iPad multitasking orientation set:

```txt
UIInterfaceOrientationPortrait
UIInterfaceOrientationPortraitUpsideDown
UIInterfaceOrientationLandscapeLeft
UIInterfaceOrientationLandscapeRight
```

Do not remove `TARGETED_DEVICE_FAMILY: "1"` unless the iPad layout and orientation behavior have been tested.

## TestFlight Upload

From the monorepo root, run the release helper directly:

```bash
apps/apple/scripts/upload-testflight.sh
```

The script increments `AgentMonitoriOS` `CURRENT_PROJECT_VERSION`, runs the
repository checks, regenerates the Xcode project, installs pods, creates a
Release archive, uploads it to TestFlight, and waits for App Store Connect to
return `VALID`.

Common options:

```bash
apps/apple/scripts/upload-testflight.sh --dry-run
apps/apple/scripts/upload-testflight.sh --skip-checks
apps/apple/scripts/upload-testflight.sh --build-number 44
apps/apple/scripts/upload-testflight.sh --no-wait
```

The script expects an App Store Connect API key at:

```txt
~/.appstoreconnect/private_keys/AuthKey_2CS3637KB9.p8
```

Override these values when needed:

```txt
APP_STORE_CONNECT_API_KEY_ID
APP_STORE_CONNECT_API_ISSUER_ID
APP_STORE_CONNECT_API_KEY_PATH
APP_STORE_TEAM_ID
APP_STORE_APPLE_ID
```

Before uploading, the script checks the built app metadata that App Store
Connect validates. Expected values for the current iPhone-only build:

```txt
CFBundleIdentifier = dev.hcg.AgentMonitor
UIDeviceFamily = [1]
UISupportedInterfaceOrientations = [UIInterfaceOrientationPortrait]
```

The generated `output/ExportOptions-TestFlight.plist` contains:

```txt
destination = upload
method = app-store-connect
signingStyle = automatic
teamID = S77C743756
manageAppVersionAndBuildNumber = true
uploadSymbols = true
stripSwiftSymbols = true
```

Common upload failures:

- `missingApp(bundleId: "dev.hcg.AgentMonitor")`: create the matching App Store Connect app record before uploading.
- App icon alpha rejection: regenerate or convert the app icon PNGs so the final PNG files have no alpha channel.
- iPad multitasking orientation rejection: confirm the archive contains `UIDeviceFamily = [1]`, or add the full iPad orientation set if iPad support is intentionally enabled.

## Package macOS App

From the monorepo root:

```bash
apps/apple/scripts/package-mac.sh
```

The package script:

1. Builds `AgentMonitorService` in release mode.
2. Builds the macOS target.
3. Embeds the Rust service binary.
4. Creates `apps/apple/dist/AgentMonitor.dmg`.

The packaged app embeds the Rust service and is self-contained at runtime.

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
- The iOS app defaults to an empty service URL. Configure one or more Mac service URLs in Settings.
- HTTP local networking is allowed because the intended deployment is LAN or Tailscale.
- Public internet exposure should use authentication and TLS.
