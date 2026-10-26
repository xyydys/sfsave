#!/bin/bash
# Runs the in-app rendering self-test in an iOS simulator and prints its log.
# Needs a simulator build first: ./build.sh simulator
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/Simulator/Build/Products/Debug-iphonesimulator/SymbolStudio.app
BUNDLE=com.runyu.symbolstudio
mkdir -p build
xcrun simctl list runtimes
UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
def version(runtime):
    tail = runtime.rsplit("iOS-", 1)[-1]
    return [int(x) if x.isdigit() else 0 for x in tail.split("-")]
for runtime in sorted((r for r in devices if "iOS" in r), key=version, reverse=True):
    for device in devices[runtime]:
        if device["name"].startswith("iPhone"):
            print(device["udid"]); sys.exit(0)
sys.exit("no iPhone simulator available")')
echo "Using simulator $UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl install "$UDID" "$APP"
xcrun simctl launch --console-pty --terminate-running-process "$UDID" "$BUNDLE" -SymbolStudioSelfTest | tee build/selftest.log
DATA=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)
rm -rf build/SelfTest && cp -R "$DATA/Documents/SelfTest" build/SelfTest
grep -q "SELFTEST-DONE failures=0" build/selftest.log
