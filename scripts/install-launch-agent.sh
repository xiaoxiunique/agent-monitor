#!/usr/bin/env zsh
set -euo pipefail

label="dev.hcg.agent-monitor"
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
target_dir="$HOME/Library/LaunchAgents"
target_plist="$target_dir/$label.plist"
uid="$(id -u)"

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
    <string>set -a; [ -f .env ] &amp;&amp; source .env; set +a; exec npm run start</string>
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
tmux kill-session -t agent-monitor-service >/dev/null 2>&1 || true

launchctl bootstrap "gui/$uid" "$target_plist"
launchctl enable "gui/$uid/$label"
launchctl kickstart -k "gui/$uid/$label"

echo "Installed $label"
echo "Logs:"
echo "  $HOME/Library/Logs/agent-monitor.log"
echo "  $HOME/Library/Logs/agent-monitor.err.log"
