#!/usr/bin/env bash
# CARBON · mac.sh
# Runs ON THE LAB iMAC. Claude Code (on the Zephyrus) calls it over SSH:
#
#   ssh lab-imac "bash ~/Desktop/carbon/ios/scripts/mac.sh <command>"
#
# Commands:
#   doctor            Show machine health: Xcode, free disk, repo state, simulators.
#   pull              Fast-forward the iMac's clone to match GitHub. Never merges.
#   switch <branch>   Check out another branch (e.g. spike/m0) and fast-forward it.
#   build             pull, then compile the iOS app for the simulator (no signing, no password).
#   test              pull, then run the unit tests on an iOS simulator.
#   logs [lines]      Copy the app's Documents/logs folder off the iPhone, print the log tail.
#   captures          Copy the app's Documents/captures off the iPhone, make JPEG copies.
#   ocr [folder] [opts]  Apple Vision OCR + CER over a folder (default ios/build/phone/captures).
#                     opts: --truth <file> | --out <dir> | --show  (see tools/ocr.swift)
#
# Exit codes:
#   0 ok · 1 build, test or copy failed · 2 bad usage · 3 iMac clone has local edits
#   4 Xcode project missing (bootstrap not done yet) · 5 disk almost full

set -euo pipefail

REPO="$HOME/Desktop/carbon"
PROJECT="$REPO/ios/Carbon.xcodeproj"
SCHEME="Carbon"
DERIVED="$REPO/ios/build/sim"
MIN_FREE_GB=10

cd "$REPO"

say() { printf '\n[mac.sh] %s\n' "$*"; }

free_gb() {
  # macOS df -g reports gigabytes. Column 4 is "Avail".
  df -g / | awk 'NR==2 {print $4}'
}

check_disk() {
  local gb
  gb="$(free_gb)"
  if [ "$gb" -lt "$MIN_FREE_GB" ]; then
    say "DISK ALMOST FULL: only ${gb} GB free (need ${MIN_FREE_GB}+)."
    say "A full disk caused the 2026-10-09 Xcode failures. Ask Russell before deleting anything."
    say "Safe to clear: ~/Library/Developer/Xcode/DerivedData, ~/Library/Caches, $REPO/ios/build"
    exit 5
  fi
}

check_project() {
  if [ ! -d "$PROJECT" ]; then
    say "ios/Carbon.xcodeproj not found. The one-time Xcode bootstrap (CLAUDE.md, section 4) is not done yet."
    exit 4
  fi
}

require_clean() {
  if [ -n "$(git status --porcelain)" ]; then
    say "The iMac clone has local changes. Nobody should edit files on the iMac."
    git status --short
    say "Ask Russell how to handle these before continuing."
    exit 3
  fi
}

do_pull() {
  require_clean
  git fetch --quiet origin
  git pull --ff-only --quiet
  say "Synced $(git rev-parse --abbrev-ref HEAD) to $(git log -1 --format='%h %s')"
}

copy_from_phone() {
  # copy_from_phone <path in the app's data container> <local destination>
  local env_file="$REPO/ios/.env.local" xcconfig="$REPO/ios/Config/Local.xcconfig" bundle_id
  if [ ! -f "$env_file" ] || [ ! -f "$xcconfig" ]; then
    say "Needs ios/.env.local (CARBON_UDID) and ios/Config/Local.xcconfig (CARBON_BUNDLE_ID)."
    exit 2
  fi
  # shellcheck disable=SC1090
  source "$env_file"
  bundle_id="$(sed -n 's/^CARBON_BUNDLE_ID *= *//p' "$xcconfig" | tr -d '[:space:]')"
  if ! xcrun devicectl device copy from --quiet \
      --device "$CARBON_UDID" \
      --domain-type appDataContainer --domain-identifier "$bundle_id" \
      --source "$1" --destination "$2" >/dev/null; then
    say "Couldn't copy $1 from the phone. Is it unlocked, on the lab network, and has the app run once?"
    exit 1
  fi
}

pick_simulator() {
  # First available iPhone simulator on an iOS 26+ runtime (CARBON's minimum).
  # Prints "UDID|Name|iOS version", e.g. "1A2B...|iPhone 17|26.3".
  # Section headers look like "-- iOS 26.3 --". Device lines look like
  # "    iPhone 17 Pro (1A2B3C4D-...) (Shutdown)".
  xcrun simctl list devices available | awk '
    /^-- iOS / { split($3, v, "."); ok = (v[1] + 0 >= 26); ver = $3; next }
    /^-- /     { ok = 0; next }
    ok && /iPhone/ {
      if (match($0, /\([0-9A-F-]+\)/)) {
        udid = substr($0, RSTART + 1, RLENGTH - 2)
        name = $0
        sub(/^[ \t]+/, "", name)
        sub(/ \(.*$/, "", name)
        print udid "|" name "|" ver
        exit
      }
    }'
}

# Everything runs inside main(), so bash has read the whole script before
# `git pull` can rewrite this file underneath it.
main() {
cmd="${1:-}"

case "$cmd" in
  doctor)
    say "Host: $(hostname) · user: $(whoami)"
    xcodebuild -version
    say "Free disk: $(free_gb) GB"
    say "Repo: $(git rev-parse --abbrev-ref HEAD) @ $(git log -1 --format='%h %s' 2>/dev/null || echo 'no commits')"
    git status --short || true
    say "iOS simulator runtimes:"
    xcrun simctl list runtimes | grep -i ios || echo "(none)"
    SIM="$(pick_simulator || true)"
    if [ -n "$SIM" ]; then
      say "Test simulator (iOS 26+): $(echo "$SIM" | cut -d'|' -f2) on iOS $(echo "$SIM" | cut -d'|' -f3)"
    else
      say "Test simulator (iOS 26+): NONE. Create one in Xcode → Window → Devices and Simulators → Simulators → +"
    fi
    ;;

  pull)
    do_pull
    ;;

  switch)
    branch="${2:-}"
    if [ -z "$branch" ]; then
      echo "usage: mac.sh switch <branch>" >&2
      exit 2
    fi
    require_clean
    git fetch --quiet origin
    git checkout --quiet "$branch"
    do_pull
    ;;

  logs)
    # The app keeps its diagnostic files in Documents/logs. devicectl copies them
    # off the phone over the network (read-only for the phone, no password).
    OUT="$REPO/ios/build/phone"
    rm -rf "$OUT/logs" && mkdir -p "$OUT"
    copy_from_phone Documents/logs "$OUT/logs"
    say "Copied to ios/build/phone/logs:"
    ls -l "$OUT/logs"
    if [ -f "$OUT/logs/lab.log" ]; then
      say "Last ${2:-150} lines of lab.log:"
      tail -n "${2:-150}" "$OUT/logs/lab.log"
    fi
    ;;

  captures)
    # Copies Documents/captures off the phone (HEIC from the glasses) and makes
    # JPEG copies for viewing and for the fixture set.
    OUT="$REPO/ios/build/phone"
    rm -rf "$OUT/captures" "$OUT/captures-jpg" && mkdir -p "$OUT/captures-jpg"
    copy_from_phone Documents/captures "$OUT/captures"
    for f in "$OUT/captures"/*; do
      [ -f "$f" ] || continue
      base="$(basename "$f")"
      sips -s format jpeg -s formatOptions 85 "$f" --out "$OUT/captures-jpg/${base%.*}.jpg" >/dev/null
    done
    say "JPEG copies in ios/build/phone/captures-jpg:"
    ls -l "$OUT/captures-jpg"
    ;;

  ocr)
    # Reader v1 (SPEC 8.4) on the Mac's Vision, with CER (SPEC 8.3). M0 uses it to pick
    # the capture configuration. Relative folders are taken from the repo root.
    folder="${2:-ios/build/phone/captures}"
    case "$folder" in /*) ;; *) folder="$REPO/$folder" ;; esac
    swift "$REPO/tools/ocr.swift" "$folder" "${@:3}"
    ;;

  build)
    check_disk
    do_pull
    check_project
    say "Building $SCHEME for the iOS Simulator (no signing)..."
    if xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "$DERIVED" \
        -quiet \
        build; then
      say "BUILD SUCCEEDED"
    else
      say "BUILD FAILED (errors above)"
      exit 1
    fi
    ;;

  test)
    check_disk
    do_pull
    check_project
    SIM="$(pick_simulator || true)"
    if [ -z "$SIM" ]; then
      say "No iPhone simulator on iOS 26+. Run: mac.sh doctor"
      exit 1
    fi
    SIM_UDID="$(echo "$SIM" | cut -d'|' -f1)"
    say "Testing $SCHEME on $(echo "$SIM" | cut -d'|' -f2) (iOS $(echo "$SIM" | cut -d'|' -f3))"
    if xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -destination "platform=iOS Simulator,id=$SIM_UDID" \
        -derivedDataPath "$DERIVED" \
        -quiet \
        test; then
      say "TESTS PASSED"
    else
      say "TESTS FAILED (details above)"
      exit 1
    fi
    ;;

  *)
    echo "usage: mac.sh doctor | pull | switch <branch> | build | test | logs [lines] | captures | ocr [folder] [opts]" >&2
    exit 2
    ;;
esac
}

main "$@"
