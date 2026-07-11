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

echo "=== Build and codesign completed successfully! ==="
