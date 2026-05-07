#!/usr/bin/env zsh
set -euo pipefail

label="dev.hcg.agent-monitor"
target_plist="$HOME/Library/LaunchAgents/$label.plist"
uid="$(id -u)"

launchctl bootout "gui/$uid" "$target_plist" >/dev/null 2>&1 || true
rm -f "$target_plist"

echo "Uninstalled $label"
