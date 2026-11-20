#!/bin/bash
# Restarts onboarding on both Demo simulators, linked so they pair for real
# (DemoPairBridge): the iPad (child) shows a code, the iPhone (parent) types
# it. The Demo app only (com.evlin.ios.demo), never the real one.
#
#   scripts/demo-pair.sh            both at pairing: the iPad's QR and code,
#                                   the iPhone's "Connect your child's device"
#   scripts/demo-pair.sh start      both at the very start (Parent / Child)
#   scripts/demo-pair.sh --build    build and install the Demo app first
#                                   (combine: scripts/demo-pair.sh start --build)
#   scripts/demo-pair.sh family     no onboarding: the sample family with its
#                                   data, the iPhone as the parent of Mia, Leo
#                                   and Ava, the iPad as Mia's device
#   scripts/demo-pair.sh light|dark both simulators in light or dark mode
#                                   (setup follows it), and the parent's
#                                   Appearance to match (Cream or Dark) for
#                                   after setup; without it, left as it is
#
# Then on the iPad: Continue, the name, and "Do you use Family Sharing?":
#   Yes -> straight to the Screen Time permission
#   No  -> "Set up Family Sharing" (or a PIN), then the same
# The iPhone waits ("Connected to Mia") and moves on by itself when the
# iPad finishes setup. Then both open as a new family: the iPad as Mia with
# no tasks, the iPhone on Home with no tasks. The two keep Mia's tasks in
# step through the same file (DemoPairSync), so a first task runs end to end:
# add a task on the iPhone, the iPad locks; send it in on the iPad
# (All done; no photo on a simulator), approve it on the iPhone, it unlocks.
set -euo pipefail
cd "$(dirname "$0")/.."

IPHONE="iPhone 17 Pro"
IPAD="iPad Pro 11-inch (M5)"
APP_ID="com.evlin.ios.demo"
BRIDGE="/tmp/evlin-demo-pair.json"
DERIVED="build/DemoPair"

where="pair"
build=false
look=""
for arg in "$@"; do
  case "$arg" in
    start) where="start" ;;
    pair) where="pair" ;;
    family|--family) where="family" ;;
    --build) build=true ;;
    light|--light) look="light" ;;
    dark|--dark) look="dark" ;;
    *) echo "Unknown option: $arg (use: pair | start | family | light | dark | --build)"; exit 1 ;;
  esac
done

udid() {
  xcrun simctl list devices available | grep -F "$1 (" | head -n 1 | grep -oE '[A-F0-9-]{36}'
}
IPHONE_ID=$(udid "$IPHONE")
IPAD_ID=$(udid "$IPAD")
if [ -z "$IPHONE_ID" ] || [ -z "$IPAD_ID" ]; then
  echo "Couldn't find the simulators \"$IPHONE\" and \"$IPAD\"."
  exit 1
fi

echo "==> Booting $IPHONE and $IPAD"
xcrun simctl boot "$IPHONE_ID" 2>/dev/null || true
xcrun simctl boot "$IPAD_ID" 2>/dev/null || true
open -a Simulator

if $build; then
  echo "==> Building the Demo app"
  xcodebuild -project Evlin.xcodeproj -scheme "Evlin Demo" \
    -destination "platform=iOS Simulator,id=$IPHONE_ID" \
    -derivedDataPath "$DERIVED" build -quiet
  APP="$DERIVED/Build/Products/Demo-iphonesimulator/Evlin.app"
  echo "==> Installing on both"
  xcrun simctl install "$IPHONE_ID" "$APP"
  xcrun simctl install "$IPAD_ID" "$APP"
fi

if ! xcrun simctl get_app_container "$IPHONE_ID" "$APP_ID" >/dev/null 2>&1 \
  || ! xcrun simctl get_app_container "$IPAD_ID" "$APP_ID" >/dev/null 2>&1; then
  echo "The Demo app isn't installed on both. Run again with --build."
  exit 1
fi

echo "==> Restarting both"
xcrun simctl terminate "$IPHONE_ID" "$APP_ID" 2>/dev/null || true
xcrun simctl terminate "$IPAD_ID" "$APP_ID" 2>/dev/null || true
rm -f "$BRIDGE"
if [ -n "$look" ]; then
  echo "==> Both in $look mode"
  xcrun simctl ui "$IPHONE_ID" appearance "$look"
  xcrun simctl ui "$IPAD_ID" appearance "$look"
  # The parent's own Appearance (Settings > Appearance), for Home after setup.
  if [ "$look" = "dark" ]; then appearance="dark"; else appearance="cream"; fi
  prefs="$(xcrun simctl get_app_container "$IPHONE_ID" "$APP_ID" data)/Library/Preferences/$APP_ID"
  xcrun simctl spawn "$IPHONE_ID" defaults write "$prefs" evlin.appearance "$appearance"
fi
# The code is typed on the iPhone; the camera can't scan on a simulator.
xcrun simctl privacy "$IPHONE_ID" grant camera "$APP_ID" 2>/dev/null || true

common=(-EvlinOnboardingPreview -EvlinPairBridge "$BRIDGE")
if [ "$where" = "family" ]; then
  # Each launch seeds the sample family afresh (DemoMode.seedIfOn), wiping
  # whatever an onboarding walkthrough left.
  xcrun simctl launch "$IPAD_ID" "$APP_ID" -EvlinKidDemo >/dev/null
  xcrun simctl launch "$IPHONE_ID" "$APP_ID" -EvlinDemo >/dev/null
  echo "==> iPhone: Home for Mia, Leo and Ava. iPad: Mia's tasks."
elif [ "$where" = "pair" ]; then
  xcrun simctl launch "$IPAD_ID" "$APP_ID" "${common[@]}" -EvlinKidOnboarding childShowCode >/dev/null
  xcrun simctl launch "$IPHONE_ID" "$APP_ID" "${common[@]}" -EvlinParentOnboarding parentPairScan >/dev/null
  echo "==> Type the code on the iPad's screen into the iPhone, then tap Connect."
else
  xcrun simctl launch "$IPAD_ID" "$APP_ID" "${common[@]}" >/dev/null
  xcrun simctl launch "$IPHONE_ID" "$APP_ID" "${common[@]}" >/dev/null
  echo "==> iPad: tap Child. iPhone: tap Parent, then go through to pairing."
fi
