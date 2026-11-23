#!/bin/zsh
# Builds PendantApp and wraps it in a signed .app bundle (no Xcode needed).
set -e
cd "$(dirname "$0")"
swift build -c release
APP="build/Pendant.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/PendantApp "$APP/Contents/MacOS/PendantApp"
cp .build/release/PendantTranscribe "$APP/Contents/MacOS/PendantTranscribe"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/pendant_drain.py "$APP/Contents/Resources/pendant_drain.py"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Project-specific paths: the Python that has pendant-cli installed, and the library folder.
ROOT="$(cd .. && pwd)"
/usr/libexec/PlistBuddy -c "Add :PendantPython string $ROOT/runtime/venv/bin/python" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :PendantDefaultLibrary string $ROOT/Library" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"
