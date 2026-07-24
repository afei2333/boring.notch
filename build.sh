#!/bin/bash
set -e

echo "=== 1. Starting Release build using Xcode ==="
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -scheme boringNotch -configuration Release -derivedDataPath .build_release build

echo "=== 2. Cleaning old app bundle in root ==="
rm -rf "./LLD-AI.app"

echo "=== 3. Copying new app bundle to root ==="
cp -R "./.build_release/Build/Products/Release/LLD-AI.app" "./LLD-AI.app"

echo "=== 4. Performing recursive deep codesign locally ==="
codesign --force --deep --sign - "./LLD-AI.app"

echo "=== 5. Verifying code signature ==="
codesign -vvv --deep "./LLD-AI.app"

echo "=== 6. Syncing to /Applications ==="
rm -rf "/Applications/LLD-AI.app"
ditto "./LLD-AI.app" "/Applications/LLD-AI.app"

echo "=== 7. Restarting app ==="
# Graceful quit first so the app can stop its helper daemons; force-kill as fallback.
osascript -e 'tell application "LLD-AI" to quit' 2>/dev/null || true
for _ in {1..10}; do pgrep -xq "LLD-AI" || break; sleep 0.5; done
pkill -x "LLD-AI" 2>/dev/null || true
# LaunchServices returns -600 if we open while the old process is still dying; retry.
for _ in {1..5}; do open "/Applications/LLD-AI.app" && break; sleep 1; done

echo "=== Build, codesign, sync and restart completed successfully! ==="
