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
- Best-effort observation: local notifications are emitted for actionable status changes such as waiting, failed, and done. iOS background execution remains system-limited; the optional audio keep-alive is not a push-notification substitute.

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
- Background mode: `audio`, used by the optional best-effort background keep-alive toggle; it is not a guarantee of always-on polling or push delivery
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

Create a signed archive from the monorepo root:

```bash
rm -rf output/AgentMonitoriOS.xcarchive
xcodebuild \
  -workspace apps/apple/AgentMonitorApple.xcworkspace \
  -scheme AgentMonitoriOS \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath output/AgentMonitoriOS.xcarchive \
  -allowProvisioningUpdates \
  archive
```

Before uploading, inspect the built app metadata that App Store Connect will validate:

```bash
plutil -p "output/AgentMonitoriOS.xcarchive/Products/Applications/Agent Monitor.app/Info.plist" \
  | rg 'UIDeviceFamily|UISupportedInterfaceOrientations|CFBundleIdentifier|CFBundleVersion|CFBundleShortVersionString' -C 2
```

Expected values for the current iPhone-only build:

```txt
CFBundleIdentifier = dev.hcg.AgentMonitor
UIDeviceFamily = [1]
UISupportedInterfaceOrientations = [UIInterfaceOrientationPortrait]
```

Upload to App Store Connect with the export options plist:

```bash
rm -rf output/TestFlightExport
xcodebuild \
  -exportArchive \
  -archivePath output/AgentMonitoriOS.xcarchive \
  -exportPath output/TestFlightExport \
  -exportOptionsPlist output/ExportOptions-TestFlight.plist \
  -allowProvisioningUpdates
```

The local `output/ExportOptions-TestFlight.plist` used for uploads should contain:

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
npm run package:mac
```

The package script:

1. Builds `AgentMonitorService` in release mode.
2. Builds the macOS target.
3. Embeds the Rust service binary.
4. Creates `apps/apple/dist/AgentMonitor.dmg`.

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
- The iOS app defaults to an empty service URL. Configure one or more Mac service URLs in Settings.
- HTTP local networking is allowed because the intended deployment is LAN or Tailscale.
- Public internet exposure should use authentication and TLS.
