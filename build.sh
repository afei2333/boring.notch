#!/bin/bash
set -e

# Xcode can keep an absolute binary-package path from the checkout this folder was copied from.
package_state=".build_release/SourcePackages/workspace-state.json"
if [[ -f "$package_state" ]]; then
    python3 - "$package_state" "$PWD/.build_release/SourcePackages" <<'PY'
import json
import sys
from pathlib import Path

state = Path(sys.argv[1])
packages = Path(sys.argv[2])
data = json.loads(state.read_text())
changed = False
for artifact in data.get("object", {}).get("artifacts", []):
    old = artifact.get("path", "")
    marker = "/SourcePackages/artifacts/"
    if marker not in old or Path(old).exists():
        continue
    local = packages / "artifacts" / old.rsplit(marker, 1)[1]
    if local.exists():
        artifact["path"] = str(local)
        changed = True
if changed:
    state.write_text(json.dumps(data, indent=2) + "\n")
PY
fi

echo "=== 1. Starting Release build using Xcode ==="
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -scheme DIHUD -configuration Release -derivedDataPath .build_release build

echo "=== 2. Cleaning old app bundle in root ==="
rm -rf "./DIHUD.app"

echo "=== 3. Copying new app bundle to root ==="
cp -R "./.build_release/Build/Products/Release/DIHUD.app" "./DIHUD.app"

echo "=== 4. Performing recursive deep codesign locally ==="
codesign --force --deep --sign - "./DIHUD.app"

echo "=== 5. Verifying code signature ==="
codesign -vvv --deep "./DIHUD.app"

echo "=== 6. Syncing to /Applications ==="
rm -rf "/Applications/DIHUD.app"
ditto "./DIHUD.app" "/Applications/DIHUD.app"

echo "=== 7. Restarting app ==="
# Graceful quit first so the app can stop its helper daemons; force-kill as fallback.
osascript -e 'tell application "DIHUD" to quit' 2>/dev/null || true
for _ in {1..10}; do pgrep -xq "DIHUD" || break; sleep 0.5; done
pkill -x "DIHUD" 2>/dev/null || true
# LaunchServices returns -600 if we open while the old process is still dying; retry.
for _ in {1..5}; do open "/Applications/DIHUD.app" && break; sleep 1; done

echo "=== Build, codesign, sync and restart completed successfully! ==="
