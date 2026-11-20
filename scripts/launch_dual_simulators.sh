#!/bin/bash
set -e

# Device identifiers or names
IPHONE_NAME="iPhone 17 Pro"
IPAD_NAME="iPad Air 11-inch (M4)"
BUNDLE_ID="com.evlin.ios"
APP_PATH="DerivedData/Build/Products/Debug-iphonesimulator/Evlin.app"

echo "==> Finding simulator UDIDs..."
IPHONE_UDID=$(xcrun simctl list devices available | grep "$IPHONE_NAME" | head -n 1 | grep -o -E '\([A-F0-9-]+\)' | tr -d '()')
IPAD_UDID=$(xcrun simctl list devices available | grep "$IPAD_NAME" | head -n 1 | grep -o -E '\([A-F0-9-]+\)' | tr -d '()')

if [ -z "$IPHONE_UDID" ] || [ -z "$IPAD_UDID" ]; then
    echo "Error: Could not find UDIDs for $IPHONE_NAME or $IPAD_NAME"
    exit 1
fi

echo "iPhone: $IPHONE_NAME ($IPHONE_UDID)"
echo "iPad:   $IPAD_NAME ($IPAD_UDID)"

echo "==> Booting simulators..."
xcrun simctl boot "$IPHONE_UDID" 2>/dev/null || true
xcrun simctl boot "$IPAD_UDID" 2>/dev/null || true
open -a Simulator

if [ "$1" == "--build" ] || [ ! -d "$APP_PATH" ]; then
    echo "==> Building app for simulator..."
    xcodegen generate
    xcodebuild -project Evlin.xcodeproj -scheme Evlin -destination "platform=iOS Simulator,name=$IPHONE_NAME" -derivedDataPath DerivedData build
fi

echo "==> Installing app on iPhone and iPad..."
xcrun simctl install "$IPHONE_UDID" "$APP_PATH"
xcrun simctl install "$IPAD_UDID" "$APP_PATH"

if [ "$1" == "--demo" ] || [ "$2" == "--demo" ]; then
    echo "==> Launching in Demo Mode (iPhone = Parent, iPad = Kid)..."
    xcrun simctl terminate "$IPHONE_UDID" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl terminate "$IPAD_UDID" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl spawn "$IPAD_UDID" defaults write "$BUNDLE_ID" EvlinKidTab -int 0
    xcrun simctl launch "$IPHONE_UDID" "$BUNDLE_ID" -EvlinDemo
    xcrun simctl launch "$IPAD_UDID" "$BUNDLE_ID" -EvlinKidDemo
else
    echo "==> Launching apps (Select 'Parent' on iPhone, 'Child' on iPad)..."
    xcrun simctl launch "$IPHONE_UDID" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl launch "$IPAD_UDID" "$BUNDLE_ID" 2>/dev/null || true
fi

osascript -e 'tell application "Simulator" to activate'
echo "==> Done! Both simulators are running."
