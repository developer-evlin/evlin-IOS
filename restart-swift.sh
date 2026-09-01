#!/bin/bash
# Rebuild EvlinSwift and relaunch it in the iOS Simulator — no LLM needed.
# Safe to run repeatedly. Reuses a fixed DerivedData path for faster
# incremental builds. Logs: /tmp/evlin_swift_build.log
set -u

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DERIVED_DATA="/tmp/evlinswift_build"
BUNDLE_ID="com.evlin.app"
DEVICE_NAME="${1:-iPhone 17 Pro}"
LOG="/tmp/evlin_swift_build.log"

echo "Restarting EvlinSwift on \"$DEVICE_NAME\"…"

# Prefer an already-booted simulator (any device) so we don't interrupt
# whatever the user has open; otherwise boot the requested one. Always
# (re)boot + wait for bootstatus since a device can report "Booted" in a
# stale listing while actually being shut down between runs.
SIMID=$(xcrun simctl list devices | grep "($DEVICE_NAME)" -A0 | grep "Booted" | grep -oE '[0-9A-F-]{36}' | head -1)
if [ -z "$SIMID" ]; then
  SIMID=$(xcrun simctl list devices available | grep "$DEVICE_NAME (" | grep -oE '[0-9A-F-]{36}' | head -1)
  if [ -z "$SIMID" ]; then
    echo "  ERROR: no simulator matching \"$DEVICE_NAME\" found."
    exit 1
  fi
fi
xcrun simctl boot "$SIMID" 2>/dev/null
open -a Simulator
xcrun simctl bootstatus "$SIMID" -b

echo "  building…"
if ! xcodebuild -project "$PROJECT_DIR/Evlin.xcodeproj" -scheme Evlin \
    -destination "platform=iOS Simulator,id=$SIMID" \
    -derivedDataPath "$DERIVED_DATA" build > "$LOG" 2>&1; then
  echo "  BUILD FAILED — see $LOG"
  tail -30 "$LOG"
  exit 1
fi

APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Evlin.app"
xcrun simctl terminate "$SIMID" "$BUNDLE_ID" 2>/dev/null
xcrun simctl install "$SIMID" "$APP_PATH"
xcrun simctl launch "$SIMID" "$BUNDLE_ID" > /dev/null

echo "  done — Evlin relaunched on $DEVICE_NAME ($SIMID)"
