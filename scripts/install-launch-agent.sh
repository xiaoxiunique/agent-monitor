#!/usr/bin/env zsh
set -euo pipefail

label="dev.hcg.agent-monitor"
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
service_dir="$project_dir/apps/apple/AgentMonitorService"
service_bin="$service_dir/target/release/agent-monitor-service"
target_dir="$HOME/Library/LaunchAgents"
target_plist="$target_dir/$label.plist"
uid="$(id -u)"

if [[ ! -x "$service_bin" ]]; then
  cargo build --release --manifest-path "$service_dir/Cargo.toml"
fi

mkdir -p "$target_dir" "$HOME/Library/Logs"
cat > "$target_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>

  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>-lc</string>
    <string>set -a; [ -f .env ] &amp;&amp; source .env; set +a; exec "$service_bin"</string>
  </array>

  <key>WorkingDirectory</key>
  <string>$project_dir</string>

  <key>RunAtLoad</key>
  <true/>

  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>

  <key>StandardOutPath</key>
  <string>$HOME/Library/Logs/agent-monitor.log</string>

  <key>StandardErrorPath</key>
  <string>$HOME/Library/Logs/agent-monitor.err.log</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
</dict>
</plist>
PLIST

launchctl bootout "gui/$uid" "$target_plist" >/dev/null 2>&1 || true

launchctl bootstrap "gui/$uid" "$target_plist"
launchctl enable "gui/$uid/$label"
launchctl kickstart -k "gui/$uid/$label"

echo "Installed $label"
echo "Logs:"
echo "  $HOME/Library/Logs/agent-monitor.log"
echo "  $HOME/Library/Logs/agent-monitor.err.log"
