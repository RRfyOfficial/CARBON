#!/usr/bin/env bash
# CARBON · deploy.sh
# For building on a Mac you reach over SSH (code written elsewhere, pushed to GitHub).
# Runs ON THE BUILD MAC: pulls, builds the app for your iPhone, signs it, and gets it onto
# the phone. From your own computer:
#
#   ssh -t <build-mac> "bash <path to the clone>/ios/deploy.sh"          phone near the Mac
#   ssh -t <build-mac> "bash <path to the clone>/ios/deploy.sh remote"   phone anywhere
#
# -t matters: the keychain unlock asks for the Mac's login password.
#
# The default mode installs and launches directly. The phone must be unlocked and on the same
# network as the Mac (or cabled to it).
#
# remote mode is for when the phone is somewhere else. It needs Tailscale 1.52 or newer on the
# Mac, the Tailscale app on the iPhone, both in the same tailnet, with MagicDNS and HTTPS
# certificates turned on for the tailnet. It builds the same signed app, serves it over HTTPS
# inside the tailnet only, and prints a page to open in Safari on the phone: tap INSTALL there.
# It stops serving when you press Enter, or after CARBON_OTA_MINUTES (default 15).
# The phone must already be registered with your Apple ID (one normal deploy does that).
#
# Building on the Mac you sit at? Just press Run in Xcode instead (README, Build it yourself).
# Free Apple ID builds expire after 7 days. Running this again renews them.

set -euo pipefail

APP="build/device/Build/Products/Debug-iphoneos/Carbon.app"

# Set by remote mode; cleanup() reads them.
TS=""
HOST=""
SERVING=""
SERVER_PID=""
OTA_DIR=""
WORK_DIR=""

say() { printf '[deploy] %s\n' "$*"; }
fail() { printf '[deploy] %s\n' "$*" >&2; exit 1; }

plist_value() {
  # plist_value <key> <plist file>
  /usr/libexec/PlistBuddy -c "Print :$1" "$2"
}

build_app() {
  # build_app <xcodebuild destination>
  xcodebuild \
    -project Carbon.xcodeproj \
    -scheme Carbon \
    -configuration Debug \
    -destination "$1" \
    -derivedDataPath build/device \
    -allowProvisioningUpdates \
    -quiet \
    build
}

# ---- Default mode: install straight onto a phone the Mac can see ----

install_direct() {
  local bundle_id
  bundle_id="$(plist_value CFBundleIdentifier "$APP/Info.plist")"
  say "Installing $bundle_id..."
  xcrun devicectl device install app --device "$CARBON_UDID" "$APP"
  say "Launching..."
  xcrun devicectl device process launch --device "$CARBON_UDID" "$bundle_id"
  say "CARBON deployed."
}

# ---- remote mode: an install page inside the tailnet ----

find_tailscale() {
  if [ -n "${CARBON_TAILSCALE:-}" ]; then
    printf '%s' "$CARBON_TAILSCALE"
  elif command -v tailscale >/dev/null 2>&1; then
    command -v tailscale
  elif [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
    printf '%s' /Applications/Tailscale.app/Contents/MacOS/Tailscale
  else
    return 1
  fi
}

remote_preflight() {
  # Everything remote mode needs, checked before the slow build.
  local version
  command -v python3 >/dev/null 2>&1 ||
    fail "python3 not found (it serves the install page). Install Xcode's command line tools."
  TS="$(find_tailscale)" ||
    fail "Tailscale isn't installed on this Mac. remote mode needs it here and on the iPhone."
  # The Mac app's binary is also its CLI; this makes sure a script gets the CLI.
  export TAILSCALE_BE_CLI=1

  version="$("$TS" version 2>/dev/null | head -1)" || true
  [ -n "$version" ] || fail "Couldn't run the Tailscale CLI at $TS."
  # `tailscale serve` took its current form in 1.52.
  if ! printf '%s\n' "$version" | awk -F. '{ exit !($1 > 1 || ($1 == 1 && $2 >= 52)) }'; then
    fail "Tailscale $version on this Mac is too old for remote mode (needs 1.52 or newer). Update it, then run this again."
  fi

  HOST="$("$TS" status --json 2>/dev/null | python3 -c '
import json, sys
try:
    status = json.load(sys.stdin)
    name = status["Self"]["DNSName"].rstrip(".")
    print(name if status.get("BackendState") == "Running" else "")
except Exception:
    print("")
')" || true
  [ -n "$HOST" ] ||
    fail "Tailscale isn't connected on this Mac, or MagicDNS is off for the tailnet. Check with: $TS status"
}

cleanup() {
  if [ -n "$SERVING" ]; then "$TS" serve --https=443 off >/dev/null 2>&1 || true; fi
  if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; fi
  if [ -n "$OTA_DIR" ]; then rm -rf "$OTA_DIR"; fi
  if [ -n "$WORK_DIR" ]; then rm -rf "$WORK_DIR"; fi
}

install_remote() {
  local sha bundle_id version expires port minutes log deadline seen_manifest seen_ipa
  sha="$(git rev-parse --short HEAD)"
  bundle_id="$(plist_value CFBundleIdentifier "$APP/Info.plist")"
  version="$(plist_value CFBundleShortVersionString "$APP/Info.plist")"
  port="${CARBON_OTA_PORT:-8765}"
  minutes="${CARBON_OTA_MINUTES:-15}"

  trap cleanup EXIT
  trap 'exit 130' INT TERM HUP
  WORK_DIR="$(mktemp -d)"
  OTA_DIR="$PWD/build/ota"
  rm -rf "$OTA_DIR"
  mkdir -p "$OTA_DIR/Payload"

  # The phone only installs a build whose provisioning profile lists it and hasn't expired.
  expires="unknown"
  if security cms -D -i "$APP/embedded.mobileprovision" > "$WORK_DIR/profile.plist" 2>/dev/null; then
    expires="$(plist_value ExpirationDate "$WORK_DIR/profile.plist" 2>/dev/null || echo unknown)"
    if ! grep -q "$CARBON_UDID" "$WORK_DIR/profile.plist"; then
      say "WARNING: this build's provisioning profile doesn't seem to list the iPhone in ios/.env.local."
      say "         If the install fails, run the normal deploy once with the phone near the Mac."
    fi
  else
    say "Couldn't read the build's provisioning profile; carrying on."
  fi
  say "This build opens until: $expires"

  # An .ipa is a zip with the app inside a Payload folder.
  say "Packaging $bundle_id ($sha)..."
  ditto "$APP" "$OTA_DIR/Payload/Carbon.app"
  ( cd "$OTA_DIR" && zip -qry "Carbon-$sha.ipa" Payload && rm -rf Payload )

  # The manifest tells iOS what to download. File names carry the commit, so Safari
  # can't hand the phone last week's copy.
  cat > "$OTA_DIR/manifest-$sha.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>items</key>
	<array>
		<dict>
			<key>assets</key>
			<array>
				<dict>
					<key>kind</key>
					<string>software-package</string>
					<key>url</key>
					<string>https://$HOST/Carbon-$sha.ipa</string>
				</dict>
			</array>
			<key>metadata</key>
			<dict>
				<key>bundle-identifier</key>
				<string>$bundle_id</string>
				<key>bundle-version</key>
				<string>$version</string>
				<key>kind</key>
				<string>software</string>
				<key>title</key>
				<string>CARBON</string>
			</dict>
		</dict>
	</array>
</dict>
</plist>
EOF

  cat > "$OTA_DIR/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>CARBON / INSTALL</title>
<style>
  body { margin: 0; padding: 48px 24px; background: #0A0A0B; color: #F4F4F1;
         font: 14px/1.6 ui-monospace, Menlo, monospace; text-transform: uppercase; letter-spacing: 0.08em; }
  h1 { font-size: 14px; font-weight: 400; margin: 0 0 32px; }
  p { margin: 0 0 8px; color: #8C8C93; }
  a { display: block; margin: 32px 0; padding: 20px; border: 1px solid #F4F4F1; color: #F4F4F1;
      text-align: center; text-decoration: none; font-size: 16px; }
</style>
</head>
<body>
<h1>CARBON / INSTALL</h1>
<p>Build · $sha · v$version</p>
<p>Opens until · $expires</p>
<a href="itms-services://?action=download-manifest&amp;url=https://$HOST/manifest-$sha.plist">Install</a>
<p>Tap install, then confirm. CARBON updates on the home screen.</p>
</body>
</html>
EOF

  # A small file server on this Mac only; Tailscale puts HTTPS in front of it. (The Tailscale
  # Mac app can't serve folders itself, only forward to a local port.)
  log="$WORK_DIR/server.log"
  python3 -u - "$port" "$OTA_DIR" > "$log" 2>&1 <<'PY' &
import functools
import http.server
import sys


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = dict(
        http.server.SimpleHTTPRequestHandler.extensions_map,
        **{".plist": "text/xml", ".ipa": "application/octet-stream"},
    )

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


port, folder = int(sys.argv[1]), sys.argv[2]
handler = functools.partial(Handler, directory=folder)
http.server.ThreadingHTTPServer(("127.0.0.1", port), handler).serve_forever()
PY
  SERVER_PID=$!
  sleep 1
  kill -0 "$SERVER_PID" 2>/dev/null ||
    fail "Couldn't start the file server on port $port (already in use?). Set CARBON_OTA_PORT to another port."

  # If HTTPS isn't enabled for the tailnet yet, this prints a link to turn it on and waits.
  say "Opening https://$HOST inside the tailnet..."
  "$TS" serve --bg --https=443 "http://127.0.0.1:$port"
  SERVING=1

  # The first request also fetches the HTTPS certificate, which can take a minute.
  if curl -fsS -o /dev/null --max-time 90 "https://$HOST/"; then
    say "Checked: the install page answers over HTTPS."
  else
    say "Couldn't load the page from this Mac (a first certificate can be slow). Try the phone anyway."
  fi

  printf '\n'
  say "On the iPhone: turn Tailscale on, then open this in Safari and tap INSTALL:"
  say ""
  say "    https://$HOST/"
  say ""
  say "Serving for up to $minutes min. Press Enter here once CARBON has installed."

  deadline=$((SECONDS + minutes * 60))
  seen_manifest=0
  seen_ipa=0
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ "$seen_manifest" = 0 ] && grep -q "GET /manifest-" "$log"; then
      say "The phone asked for the build..."
      seen_manifest=1
    fi
    if [ "$seen_ipa" = 0 ] && grep -q "GET /Carbon-" "$log"; then
      say "The phone is downloading it. Watch the CARBON icon on the home screen."
      seen_ipa=1
    fi
    if [ -t 0 ]; then
      if read -r -t 2 _; then break; fi
    else
      sleep 2
    fi
  done

  if [ "$seen_ipa" = 1 ]; then
    say "Stopped serving. Open CARBON on the phone to check it."
  else
    say "Stopped serving. The phone never downloaded the build."
  fi
}

# Everything runs inside main(), so bash has read the whole script before
# `git pull` can rewrite this file underneath it.
main() {
  local mode="${1:-device}"
  case "$mode" in
    device|remote) ;;
    *) echo "usage: deploy.sh [remote]" >&2; exit 2 ;;
  esac

  cd "$(dirname "$0")"

  if [ ! -f .env.local ]; then
    echo "[deploy] Missing ios/.env.local. Copy .env.local.example to .env.local and put your iPhone's UDID in it."
    exit 1
  fi
  if [ ! -f Config/Local.xcconfig ]; then
    echo "[deploy] Missing ios/Config/Local.xcconfig (Team ID + bundle ID). Run: bash ios/scripts/setup.sh"
    exit 1
  fi
  # shellcheck disable=SC1091
  source .env.local
  : "${CARBON_UDID:?CARBON_UDID is empty in ios/.env.local}"

  if [ "$mode" = remote ]; then
    remote_preflight
  fi

  # 1. Get the latest code from GitHub (refuses if this clone has local edits)
  bash scripts/mac.sh pull

  # 2. Code signing over SSH needs the login keychain unlocked. Prompts, never stores the password.
  security unlock-keychain ~/Library/Keychains/login.keychain-db

  if [ "$mode" = remote ]; then
    # 3. Build for any iPhone: the phone doesn't have to be visible to this Mac.
    say "Building for the iPhone (remote: the phone doesn't need to be nearby)..."
    build_app "generic/platform=iOS"
    # 4. Serve it inside the tailnet for the phone to install.
    install_remote
  else
    # 3. Build for the real device
    say "Building for the iPhone..."
    build_app "id=$CARBON_UDID"
    # 4. Install and launch (no debugger attached, which avoids most iOS 27 quirks)
    install_direct
  fi
}

main "$@"
