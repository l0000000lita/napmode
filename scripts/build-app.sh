#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product NapMode
APP="NapMode.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/release/NapMode" "$APP/Contents/MacOS/NapMode"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
