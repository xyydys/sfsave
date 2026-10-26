#!/bin/bash
# Runs the in-app rendering self-test in an iOS simulator and prints its log.
#   Scripts/selftest.sh boot   start booting a simulator early (optional)
#   Scripts/selftest.sh        install the simulator build and run the test
# Needs a simulator build first: ./build.sh simulator
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/Simulator/Build/Products/Debug-iphonesimulator/SymbolStudio.app
BUNDLE=com.runyu.symbolstudio
mkdir -p build

pick_simulator() {
  xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
def version(runtime):
    tail = runtime.rsplit("iOS-", 1)[-1]
    return [int(x) if x.isdigit() else 0 for x in tail.split("-")]
for runtime in sorted((r for r in devices if "iOS" in r), key=version, reverse=True):
    for device in devices[runtime]:
        if device["name"].startswith("iPhone"):
            print(device["udid"]); sys.exit(0)
sys.exit("no iPhone simulator available")'
}

if [ -f build/simulator-udid ]; then UDID=$(cat build/simulator-udid); else UDID=$(pick_simulator); echo "$UDID" > build/simulator-udid; fi
if [ "${1:-}" = "boot" ]; then
  echo "Booting simulator $UDID"
  xcrun simctl boot "$UDID" 2>/dev/null || true
  exit 0
fi

echo "Using simulator $UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b > /dev/null
xcrun simctl install "$UDID" "$APP"
xcrun simctl launch --console-pty --terminate-running-process "$UDID" "$BUNDLE" -SymbolStudioSelfTest | tee build/selftest.log
DATA=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)
rm -rf build/SelfTest && cp -R "$DATA/Documents/SelfTest" build/SelfTest
grep -q "SELFTEST-DONE failures=0" build/selftest.log
