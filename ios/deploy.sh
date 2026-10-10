#!/usr/bin/env bash
# CARBON · deploy.sh
# Runs ON THE LAB iMAC. Builds the app for Russell's iPhone, signs it,
# installs it, and launches it. Russell runs it from the Zephyrus:
#
#   ssh -t lab-imac "bash ~/Desktop/carbon/ios/deploy.sh"
#
# -t matters: the keychain unlock asks for the iMac password.
# The phone must be unlocked and on the lab network (or cabled to the iMac).
# Free Apple ID builds expire after 7 days. Running this again renews them.

set -euo pipefail

main() {
  cd "$(dirname "$0")"

  if [ ! -f .env.local ]; then
    echo "[deploy] Missing ios/.env.local. Copy .env.local.example to .env.local and fill it in (CLAUDE.md, section 4)."
    exit 1
  fi
  if [ ! -f Config/Local.xcconfig ]; then
    echo "[deploy] Missing ios/Config/Local.xcconfig (Team ID + bundle ID). See CLAUDE.md, section 4."
    exit 1
  fi
  # shellcheck disable=SC1091
  source .env.local
  : "${CARBON_UDID:?CARBON_UDID is empty in ios/.env.local}"

  # 1. Get the latest code from GitHub (refuses if the iMac clone has local edits)
  bash scripts/mac.sh pull

  # 2. Code signing over SSH needs the login keychain unlocked. Prompts, never stores the password.
  security unlock-keychain ~/Library/Keychains/login.keychain-db

  # 3. Build for the real device
  echo "[deploy] Building for the iPhone..."
  xcodebuild \
    -project Carbon.xcodeproj \
    -scheme Carbon \
    -configuration Debug \
    -destination "id=$CARBON_UDID" \
    -derivedDataPath build/device \
    -allowProvisioningUpdates \
    -quiet \
    build

  # 4. Install and launch (no debugger attached, which avoids most iOS 27 quirks)
  APP="build/device/Build/Products/Debug-iphoneos/Carbon.app"
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
  echo "[deploy] Installing $BUNDLE_ID..."
  xcrun devicectl device install app --device "$CARBON_UDID" "$APP"
  echo "[deploy] Launching..."
  xcrun devicectl device process launch --device "$CARBON_UDID" "$BUNDLE_ID"

  echo "[deploy] CARBON deployed."
}

main "$@"
