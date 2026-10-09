#!/usr/bin/env bash
# CARBON · mac.sh
# Runs ON THE LAB iMAC. Claude Code (on the Zephyrus) calls it over SSH:
#
#   ssh lab-imac "~/Desktop/carbon/ios/scripts/mac.sh <command>"
#
# Commands:
#   doctor   Show machine health: Xcode, free disk, repo state, simulators.
#   pull     Fast-forward the iMac's clone to match GitHub. Never merges.
#   build    pull, then compile the iOS app for the simulator (no signing, no password).
#   test     pull, then run the unit tests on an iOS simulator.
#
# Exit codes:
#   0 ok · 1 build or test failed · 2 bad usage · 3 iMac clone has local edits
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

do_pull() {
  if [ -n "$(git status --porcelain)" ]; then
    say "The iMac clone has local changes. Nobody should edit files on the iMac."
    git status --short
    say "Ask Russell how to handle these before continuing."
    exit 3
  fi
  git fetch --quiet origin
  git pull --ff-only --quiet
  say "Synced to $(git log -1 --format='%h %s')"
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
    echo "usage: mac.sh doctor | pull | build | test" >&2
    exit 2
    ;;
esac
}

main "$@"
