#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MONOREPO_DIR="$(cd "$ROOT_DIR/../.." && pwd)"
SERVICE_DIR="$MONOREPO_DIR"
RUST_SERVICE_DIR="$ROOT_DIR/AgentMonitorService"
DERIVED_DATA_DIR="$ROOT_DIR/.build/DerivedData"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="Agent Monitor.app"
APP_PATH="$DIST_DIR/$APP_NAME"
DMG_PATH="$DIST_DIR/AgentMonitor.dmg"

cd "$SERVICE_DIR"
npm run build:web

cd "$ROOT_DIR"
cargo build --release --manifest-path "$RUST_SERVICE_DIR/Cargo.toml"

xcodegen generate
xcodebuild \
  -project AgentMonitorApple.xcodeproj \
  -scheme AgentMonitorMac \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  -configuration Release \
  build

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
ditto "$DERIVED_DATA_DIR/Build/Products/Release/$APP_NAME" "$APP_PATH"

RESOURCES_DIR="$APP_PATH/Contents/Resources"
PUBLIC_RESOURCE_DIR="$RESOURCES_DIR/public"
mkdir -p "$PUBLIC_RESOURCE_DIR"

rsync -a --delete \
  --exclude '.git' \
  --exclude '.DS_Store' \
  "$SERVICE_DIR/public" \
  "$RESOURCES_DIR/"

mkdir -p "$PUBLIC_RESOURCE_DIR/vendor"
cp "$SERVICE_DIR/node_modules/@xterm/xterm/css/xterm.css" "$PUBLIC_RESOURCE_DIR/vendor/xterm.css"
cp "$SERVICE_DIR/node_modules/@xterm/xterm/lib/xterm.js" "$PUBLIC_RESOURCE_DIR/vendor/xterm.js"
cp "$SERVICE_DIR/node_modules/@xterm/addon-fit/lib/addon-fit.js" "$PUBLIC_RESOURCE_DIR/vendor/addon-fit.js"

cp "$RUST_SERVICE_DIR/target/release/agent-monitor-service" "$RESOURCES_DIR/agent-monitor-service"
chmod 755 "$RESOURCES_DIR/agent-monitor-service"

codesign --force --deep --sign - "$APP_PATH"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "Agent Monitor" \
  -srcfolder "$APP_PATH" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "$APP_PATH"
echo "$DMG_PATH"
