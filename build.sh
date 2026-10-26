#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo '需要 macOS 与完整 Xcode。iPhone 终端无法直接编译 SwiftUI App；可用附带的 GitHub Actions。' >&2
  exit 1
fi
build_mode="${1:-device}"
case "$build_mode" in
  device)
    xcodebuild -project SymbolStudio.xcodeproj -scheme SymbolStudio -configuration Release \
      -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData \
      CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
    python3 Scripts/package_ipa.py
    ;;
  simulator)
    xcodebuild -project SymbolStudio.xcodeproj -scheme SymbolStudio -configuration Debug \
      -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath build/Simulator \
      CODE_SIGNING_ALLOWED=NO build
    ;;
  *) echo '用法：./build.sh [device|simulator]' >&2; exit 2 ;;
esac
