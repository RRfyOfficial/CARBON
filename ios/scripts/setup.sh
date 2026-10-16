#!/usr/bin/env bash
# CARBON · setup.sh: run once on your Mac after cloning (SPEC M5, README "Build it yourself").
#
#   bash ios/scripts/setup.sh [--team TEAMID] [--bundle com.you.Carbon] [--yes] [--dry-run] [--no-open]
#
# Checks Xcode, finds your Apple Team ID from your signing certificate, suggests a bundle ID,
# writes ios/Config/Local.xcconfig (gitignored: your identity never enters the repo), and opens
# the project in Xcode. --yes accepts the suggestions; --dry-run writes nothing.
# Written for the bash 3.2 that ships with macOS.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCAL="$REPO/ios/Config/Local.xcconfig"
PROJECT="$REPO/ios/Carbon.xcodeproj"
MIN_XCODE=26

team=""
bundle=""
yes=0
dry=0
open_project=1
while [ $# -gt 0 ]; do
  case "$1" in
    --team) team="${2:-}"; shift 2 ;;
    --bundle) bundle="${2:-}"; shift 2 ;;
    --yes|-y) yes=1; shift ;;
    --dry-run) dry=1; shift ;;
    --no-open) open_project=0; shift ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
done

say() { printf '[setup] %s\n' "$*"; }
fail() { printf '\n[setup] %s\n' "$*" >&2; exit 1; }

# Asks a question with a default; with --yes (or no terminal) the default wins.
ask() {
  local prompt="$1" default="$2" answer=""
  if [ "$yes" = 1 ] || [ ! -t 0 ]; then
    printf '%s' "$default"
    return
  fi
  read -r -p "[setup] $prompt [$default]: " answer
  printf '%s' "${answer:-$default}"
}

# 1. Xcode 26 or newer (the iOS 26 SDK).
command -v xcodebuild >/dev/null 2>&1 ||
  fail "Xcode isn't installed. Install Xcode $MIN_XCODE or newer from the App Store, open it once, then run this again."
xcode_version="$(xcodebuild -version 2>/dev/null | awk 'NR == 1 { print $2 }')"
[ -n "$xcode_version" ] ||
  fail "xcodebuild didn't run. Open Xcode once to finish installing it, then run: sudo xcode-select -s /Applications/Xcode.app"
if [ "${xcode_version%%.*}" -lt "$MIN_XCODE" ]; then
  fail "Found Xcode $xcode_version. CARBON needs Xcode $MIN_XCODE or newer."
fi
say "Xcode $xcode_version: OK"
[ -d "$PROJECT" ] || fail "ios/Carbon.xcodeproj is missing. Run this from a full clone of the repo."

# 2. Team ID: the OU field of each Apple Development signing identity in your keychain.
if [ -z "$team" ]; then
  candidates=""
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    subject="$(security find-certificate -c "$name" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null || true)"
    ou="$(printf '%s' "$subject" | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p')"
    org="$(printf '%s' "$subject" | sed -n 's/.*[ ,/]O *= *\([^,/]*\).*/\1/p')"
    [ -n "$ou" ] || continue
    case "$candidates" in *"$ou"*) ;; *) candidates="${candidates}${ou}|${org:-unknown}"$'\n' ;; esac
  done < <(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p')

  count="$(printf '%s' "$candidates" | grep -c . || true)"
  if [ "$count" = 0 ]; then
    fail "No Apple Development certificate found. In Xcode: Settings › Accounts › add your Apple ID (a free one works) › Manage Certificates › + › Apple Development. Then run this again, or pass --team YOURTEAMID."
  elif [ "$count" = 1 ]; then
    team="${candidates%%|*}"
    say "Team ID $team ($(printf '%s' "$candidates" | head -1 | cut -d'|' -f2))"
  else
    say "Several teams are signed in on this Mac:"
    printf '%s' "$candidates" | awk -F'|' '{ printf "          %d) %s  %s\n", NR, $1, $2 }'
    if [ "$yes" = 1 ] || [ ! -t 0 ]; then
      fail "Pick one with --team TEAMID."
    fi
    pick="$(ask "Which one (number)" 1)"
    team="$(printf '%s' "$candidates" | sed -n "${pick}p" | cut -d'|' -f1)"
    [ -n "$team" ] || fail "There's no team number $pick."
  fi
fi
printf '%s' "$team" | grep -Eq '^[A-Z0-9]{10}$' || fail "\"$team\" doesn't look like a Team ID (10 letters and digits)."

# 3. Bundle ID: unique to you; letters, digits and dots only (the toolkit rejects hyphens).
if [ -z "$bundle" ]; then
  user="$(id -un | tr -cd 'A-Za-z0-9' | tr 'A-Z' 'a-z')"
  bundle="$(ask "Bundle ID for your copy of CARBON" "com.${user:-builder}.Carbon")"
fi
printf '%s' "$bundle" | grep -Eq '^[A-Za-z][A-Za-z0-9]*(\.[A-Za-z][A-Za-z0-9]*)+$' ||
  fail "\"$bundle\" isn't a valid bundle ID here: use letters, digits and dots, like com.yourname.Carbon (no hyphens)."

# 4. Local.xcconfig.
content="// CARBON · Local.xcconfig, written by ios/scripts/setup.sh. Gitignored: never commit it.
DEVELOPMENT_TEAM = $team
CARBON_BUNDLE_ID = $bundle"

if [ "$dry" = 1 ]; then
  say "Dry run. Would write ios/Config/Local.xcconfig:"
  printf '%s\n' "$content" | sed 's/^/          /'
  exit 0
fi
if [ -f "$LOCAL" ] && ! grep -q "DEVELOPMENT_TEAM = $team" "$LOCAL"; then
  say "ios/Config/Local.xcconfig already exists:"
  sed 's/^/          /' "$LOCAL"
  case "$(ask "Replace it (y/n)" y)" in [Yy]*) ;; *) fail "Kept your existing Local.xcconfig." ;; esac
fi
printf '%s\n' "$content" > "$LOCAL"
say "Wrote ios/Config/Local.xcconfig (team $team, bundle $bundle)"

# 5. Next steps.
cat <<EOF
[setup] Next, in Xcode:
          1. Wait for the Meta Wearables package to finish resolving (top of the window).
          2. Plug in your iPhone (iOS 26+), pick it next to the Carbon scheme, and press Run.
          3. First time only: on the iPhone, turn on Settings › Privacy & Security › Developer Mode,
             and trust your Apple ID in Settings › General › VPN & Device Management.
        Then follow README.md › Build it yourself for the glasses side (Meta AI Developer Mode).
EOF
if [ "$open_project" = 1 ]; then
  open "$PROJECT"
fi
