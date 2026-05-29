#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MONOREPO_DIR="$(cd "$ROOT_DIR/../.." && pwd)"
PROJECT_FILE="$ROOT_DIR/project.yml"
OUTPUT_DIR="${TF_OUTPUT_DIR:-$MONOREPO_DIR/output}"
LOG_DIR="$OUTPUT_DIR/logs"

SCHEME="${TF_SCHEME:-AgentMonitoriOS}"
WORKSPACE="$ROOT_DIR/AgentMonitorApple.xcworkspace"
APP_NAME="${TF_APP_NAME:-Agent Monitor.app}"
BUNDLE_ID="${TF_BUNDLE_ID:-dev.hcg.AgentMonitor}"
APPLE_ID="${APP_STORE_APPLE_ID:-6769085984}"
TEAM_ID="${APP_STORE_TEAM_ID:-${ASC_TEAM_ID:-S77C743756}}"
ASC_KEY_ID="${APP_STORE_CONNECT_API_KEY_ID:-${ASC_KEY_ID:-2CS3637KB9}}"
ASC_ISSUER_ID="${APP_STORE_CONNECT_API_ISSUER_ID:-${ASC_ISSUER_ID:-3d675f41-0a07-45c7-94ec-0e569e370e3f}}"
ASC_KEY_PATH="${APP_STORE_CONNECT_API_KEY_PATH:-${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}}"

RUN_CHECKS="${TF_RUN_CHECKS:-1}"
INCREMENT_BUILD="${TF_INCREMENT_BUILD:-1}"
WAIT_FOR_VALID="${TF_WAIT_FOR_VALID:-1}"
INTERNAL_ONLY="${TF_INTERNAL_ONLY:-1}"
REQUESTED_BUILD="${TF_BUILD_NUMBER:-}"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: npm run tf -- [options]

Builds AgentMonitoriOS, uploads it to TestFlight, and waits for App Store
Connect to mark the delivery VALID.

Options:
  --build-number N   Use an explicit iOS build number instead of current + 1.
  --no-increment     Reuse the build number currently in apps/apple/project.yml.
  --skip-checks      Skip npm run check and npm run check:rust.
  --no-wait          Do not wait for App Store Connect build status.
  --dry-run          Print the resolved release settings without changing files.
  -h, --help         Show this help.

Environment overrides:
  APP_STORE_CONNECT_API_KEY_ID       Default: 2CS3637KB9
  APP_STORE_CONNECT_API_ISSUER_ID    Default: 3d675f41-0a07-45c7-94ec-0e569e370e3f
  APP_STORE_CONNECT_API_KEY_PATH     Default: ~/.appstoreconnect/private_keys/AuthKey_<key>.p8
  APP_STORE_TEAM_ID                  Default: S77C743756
  APP_STORE_APPLE_ID                 Default: 6769085984
  TF_BUILD_NUMBER                    Same as --build-number
  TF_RUN_CHECKS=0                    Same as --skip-checks
  TF_WAIT_FOR_VALID=0                Same as --no-wait
  TF_INTERNAL_ONLY=0                 Allow non-internal TestFlight distribution.
EOF
}

log() {
  printf '\n==> %s\n' "$*"
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

plist_bool() {
  if [[ "$1" == "1" || "$1" == "true" || "$1" == "YES" ]]; then
    printf '<true/>'
  else
    printf '<false/>'
  fi
}

read_project_build_number() {
  ruby -ryaml -e '
    value = YAML.load_file(ARGV[0]).dig("targets", "AgentMonitoriOS", "settings", "base", "CURRENT_PROJECT_VERSION")
    abort("Missing AgentMonitoriOS CURRENT_PROJECT_VERSION") if value.nil?
    puts value
  ' "$PROJECT_FILE"
}

update_project_build_number() {
  local next_build="$1"
  ruby - "$PROJECT_FILE" "$next_build" <<'RUBY'
path, next_build = ARGV
lines = File.readlines(path)
in_ios_target = false
updated = false

lines.map! do |line|
  if line =~ /^  AgentMonitoriOS:\s*$/
    in_ios_target = true
  elsif in_ios_target && line =~ /^  [A-Za-z0-9_]+:\s*$/
    in_ios_target = false
  end

  if in_ios_target && line =~ /^(\s*CURRENT_PROJECT_VERSION:\s*)"?[0-9]+"?([ \t]*)\r?\n?$/
    updated = true
    "#{$1}\"#{next_build}\"#{$2}\n"
  else
    line
  end
end

abort("Could not update AgentMonitoriOS CURRENT_PROJECT_VERSION") unless updated
File.write(path, lines.join)
RUBY
}

read_plist_value() {
  local plist="$1"
  local key_path="$2"
  /usr/libexec/PlistBuddy -c "Print :$key_path" "$plist" 2>/dev/null || true
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-number)
      [[ $# -ge 2 ]] || fail "--build-number requires a value"
      REQUESTED_BUILD="$2"
      shift 2
      ;;
    --no-increment)
      INCREMENT_BUILD=0
      shift
      ;;
    --skip-checks)
      RUN_CHECKS=0
      shift
      ;;
    --no-wait)
      WAIT_FOR_VALID=0
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
done

require_cmd ruby
require_cmd xcodegen
require_cmd pod
require_cmd xcodebuild
require_cmd xcrun
require_cmd plutil

[[ -f "$PROJECT_FILE" ]] || fail "Missing project file: $PROJECT_FILE"
[[ -f "$ASC_KEY_PATH" ]] || fail "Missing App Store Connect key: $ASC_KEY_PATH"
[[ -n "$ASC_KEY_ID" ]] || fail "APP_STORE_CONNECT_API_KEY_ID is empty"
[[ -n "$ASC_ISSUER_ID" ]] || fail "APP_STORE_CONNECT_API_ISSUER_ID is empty"

current_build="$(read_project_build_number)"
[[ "$current_build" =~ ^[0-9]+$ ]] || fail "Current build number is not numeric: $current_build"

if [[ -n "$REQUESTED_BUILD" ]]; then
  next_build="$REQUESTED_BUILD"
elif [[ "$INCREMENT_BUILD" == "1" ]]; then
  next_build="$((current_build + 1))"
else
  next_build="$current_build"
fi

[[ "$next_build" =~ ^[0-9]+$ ]] || fail "Next build number is not numeric: $next_build"

archive_path="${TF_ARCHIVE_PATH:-$OUTPUT_DIR/AgentMonitoriOS-build${next_build}.xcarchive}"
export_path="${TF_EXPORT_PATH:-$OUTPUT_DIR/TestFlightExport-build${next_build}}"
export_options_plist="${TF_EXPORT_OPTIONS_PLIST:-$OUTPUT_DIR/ExportOptions-TestFlight.plist}"
archive_log="$LOG_DIR/testflight-build${next_build}-archive.log"
export_log="$LOG_DIR/testflight-build${next_build}-export.log"
status_log="$LOG_DIR/testflight-build${next_build}-status.log"

cat <<EOF
TestFlight release settings
  Scheme:       $SCHEME
  Bundle ID:    $BUNDLE_ID
  Apple ID:     $APPLE_ID
  Team ID:      $TEAM_ID
  Build:        $current_build -> $next_build
  Archive:      $archive_path
  Export path:  $export_path
  ASC key:      $ASC_KEY_ID ($ASC_KEY_PATH)
EOF

if [[ "$DRY_RUN" == "1" ]]; then
  log "Dry run complete; no files changed."
  exit 0
fi

mkdir -p "$OUTPUT_DIR" "$LOG_DIR"

if [[ "$next_build" != "$current_build" ]]; then
  log "Bumping iOS build number to $next_build"
  update_project_build_number "$next_build"
fi

if [[ "$RUN_CHECKS" == "1" ]]; then
  log "Running repository checks"
  (cd "$MONOREPO_DIR" && npm run check)
  (cd "$MONOREPO_DIR" && npm run check:rust)
fi

log "Generating Xcode project and installing pods"
(cd "$ROOT_DIR" && xcodegen generate && pod install)

cat > "$export_options_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>upload</string>
  <key>manageAppVersionAndBuildNumber</key>
  <true/>
  <key>method</key>
  <string>app-store-connect</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>teamID</key>
  <string>$TEAM_ID</string>
  <key>testFlightInternalTestingOnly</key>
  $(plist_bool "$INTERNAL_ONLY")
  <key>uploadSymbols</key>
  <true/>
</dict>
</plist>
EOF

log "Creating Release archive"
rm -rf "$archive_path"
xcodebuild \
  -workspace "$WORKSPACE" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive_path" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  archive | tee "$archive_log"

app_info_plist="$archive_path/Products/Applications/$APP_NAME/Info.plist"
[[ -f "$app_info_plist" ]] || fail "Archive app Info.plist not found: $app_info_plist"

archive_bundle_id="$(read_plist_value "$app_info_plist" CFBundleIdentifier)"
archive_short_version="$(read_plist_value "$app_info_plist" CFBundleShortVersionString)"
archive_build="$(read_plist_value "$app_info_plist" CFBundleVersion)"
device_family="$(read_plist_value "$app_info_plist" UIDeviceFamily:0)"
orientation="$(read_plist_value "$app_info_plist" UISupportedInterfaceOrientations:0)"
encryption="$(read_plist_value "$app_info_plist" ITSAppUsesNonExemptEncryption)"

log "Archive metadata"
printf '  Bundle ID:    %s\n' "$archive_bundle_id"
printf '  Version:      %s\n' "$archive_short_version"
printf '  Build:        %s\n' "$archive_build"
printf '  Device:       UIDeviceFamily[0]=%s\n' "$device_family"
printf '  Orientation:  %s\n' "$orientation"
printf '  Encryption:   %s\n' "$encryption"

[[ "$archive_bundle_id" == "$BUNDLE_ID" ]] || fail "Unexpected bundle id: $archive_bundle_id"
[[ "$archive_build" == "$next_build" ]] || fail "Archive build $archive_build does not match expected $next_build"
[[ "$device_family" == "1" ]] || fail "Archive is not iPhone-only; UIDeviceFamily[0]=$device_family"
[[ "$orientation" == "UIInterfaceOrientationPortrait" ]] || fail "Archive is not portrait-only; first orientation=$orientation"

log "Uploading archive to TestFlight"
rm -rf "$export_path"
xcodebuild \
  -exportArchive \
  -archivePath "$archive_path" \
  -exportPath "$export_path" \
  -exportOptionsPlist "$export_options_plist" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" | tee "$export_log"

archive_info_plist="$archive_path/Info.plist"
delivery_id="$(read_plist_value "$archive_info_plist" Distributions:0:identifier)"
uploaded_build="$(read_plist_value "$archive_info_plist" Distributions:0:uploadedBuildNumber)"
uploaded_build="${uploaded_build:-$next_build}"

if [[ "$uploaded_build" =~ ^[0-9]+$ && "$uploaded_build" != "$next_build" ]]; then
  log "Xcode uploaded build $uploaded_build; updating project.yml to match"
  update_project_build_number "$uploaded_build"
fi

if [[ -n "$delivery_id" ]]; then
  log "Delivery ID: $delivery_id"
else
  log "Delivery ID was not written to archive metadata; status check will use app/build fields."
fi

if [[ "$WAIT_FOR_VALID" == "1" ]]; then
  log "Waiting for App Store Connect build status"
  export API_PRIVATE_KEYS_DIR="$(dirname "$ASC_KEY_PATH")"
  status_cmd=(xcrun altool --build-status --wait --api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID" --output-format normal)
  if [[ -n "$delivery_id" ]]; then
    status_cmd+=(--delivery-id "$delivery_id")
  else
    status_cmd+=(--apple-id "$APPLE_ID" --bundle-version "$uploaded_build" --bundle-short-version-string "$archive_short_version" --platform ios)
  fi

  "${status_cmd[@]}" | tee "$status_log"
  if ! grep -Eq '(^|[^A-Z])VALID([^A-Z]|$)' "$status_log"; then
    fail "App Store Connect did not report VALID. See $status_log"
  fi
fi

log "TestFlight upload complete"
printf '  Build:       %s\n' "$uploaded_build"
printf '  Archive:     %s\n' "$archive_path"
printf '  Export log:  %s\n' "$export_log"
[[ -n "$delivery_id" ]] && printf '  Delivery ID: %s\n' "$delivery_id"
