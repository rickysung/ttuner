#!/usr/bin/env bash
# Build a Release archive, export an IPA, and upload to TestFlight.
#
# Requires App Store Connect API Key credentials (env vars):
#   APP_STORE_CONNECT_API_KEY_ID         e.g. ABCDE12345
#   APP_STORE_CONNECT_API_KEY_ISSUER_ID  UUID
#   APP_STORE_CONNECT_API_KEY_PATH       absolute path to AuthKey_*.p8
#
# Optional:
#   ARCHIVE_PATH   override archive output (default: build/ttuner.xcarchive)
#   EXPORT_PATH    override IPA output dir (default: build/export)
#   BUMP_BUILD     "1" to auto-bump CFBundleVersion based on epoch
#
# Usage:
#   scripts/testflight.sh            # full pipeline
#   scripts/testflight.sh archive    # archive only
#   scripts/testflight.sh export     # export only (requires existing archive)
#   scripts/testflight.sh upload     # upload only (requires existing IPA)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SCHEME=ttuner
PROJECT=ttuner.xcodeproj
ARCHIVE_PATH="${ARCHIVE_PATH:-$ROOT/build/ttuner.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-$ROOT/build/export}"
EXPORT_OPTIONS="$ROOT/scripts/ExportOptions.plist"

require_env() {
    local var=$1
    if [ -z "${!var:-}" ]; then
        echo "✗ \$$var is not set." >&2
        exit 1
    fi
}

require_auth() {
    require_env APP_STORE_CONNECT_API_KEY_ID
    require_env APP_STORE_CONNECT_API_KEY_ISSUER_ID
    require_env APP_STORE_CONNECT_API_KEY_PATH
    if [ ! -f "$APP_STORE_CONNECT_API_KEY_PATH" ]; then
        echo "✗ API key file not found: $APP_STORE_CONNECT_API_KEY_PATH" >&2
        exit 1
    fi
}

bump_build_number() {
    if [ "${BUMP_BUILD:-0}" != "1" ]; then return; fi
    local plist="$ROOT/ttuner/Resources/Info.plist"
    local epoch
    epoch=$(date +%s)
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $epoch" "$plist"
    echo "→ CFBundleVersion bumped to $epoch"
}

archive_step() {
    require_auth
    bump_build_number
    rm -rf "$ARCHIVE_PATH"
    mkdir -p "$(dirname "$ARCHIVE_PATH")"
    echo "→ Archiving (Release, generic iOS)..."
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Release \
        -destination 'generic/platform=iOS' \
        -archivePath "$ARCHIVE_PATH" \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$APP_STORE_CONNECT_API_KEY_PATH" \
        -authenticationKeyID "$APP_STORE_CONNECT_API_KEY_ID" \
        -authenticationKeyIssuerID "$APP_STORE_CONNECT_API_KEY_ISSUER_ID" \
        archive
    echo "✓ Archive: $ARCHIVE_PATH"
}

export_step() {
    require_auth
    rm -rf "$EXPORT_PATH"
    mkdir -p "$EXPORT_PATH"
    echo "→ Exporting IPA via ${EXPORT_OPTIONS}..."
    xcodebuild \
        -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportOptionsPlist "$EXPORT_OPTIONS" \
        -exportPath "$EXPORT_PATH" \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$APP_STORE_CONNECT_API_KEY_PATH" \
        -authenticationKeyID "$APP_STORE_CONNECT_API_KEY_ID" \
        -authenticationKeyIssuerID "$APP_STORE_CONNECT_API_KEY_ISSUER_ID"
    echo "✓ Export complete: $EXPORT_PATH"
    ls -la "$EXPORT_PATH"
}

upload_step() {
    require_auth
    local ipa
    ipa=$(ls "$EXPORT_PATH"/*.ipa 2>/dev/null | head -n 1 || true)
    if [ -z "$ipa" ]; then
        echo "✗ No IPA found in $EXPORT_PATH. Run export first." >&2
        exit 1
    fi
    echo "→ Uploading ${ipa} to App Store Connect..."
    xcrun altool --upload-app \
        --type ios \
        --file "$ipa" \
        --apiKey "$APP_STORE_CONNECT_API_KEY_ID" \
        --apiIssuer "$APP_STORE_CONNECT_API_KEY_ISSUER_ID" \
        --output-format json
    echo "✓ Upload submitted. Watch processing status in App Store Connect → TestFlight."
}

case "${1:-all}" in
    archive)  archive_step ;;
    export)   export_step ;;
    upload)   upload_step ;;
    all|"")   archive_step; export_step; upload_step ;;
    *)        echo "Unknown step: $1 (use archive|export|upload|all)" >&2; exit 2 ;;
esac
