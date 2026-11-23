#!/bin/zsh
# Builds PendantApp and wraps it in a signed .app bundle (no Xcode needed).
#   ./build.sh            build only (also refreshes an installed copy, if there is one)
#   ./build.sh --install  build and copy the app into the Applications folder
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

# Install into Applications so it shows up in Finder, Launchpad and Spotlight.
# Prefers /Applications; falls back to ~/Applications if that is not writable.
installed_copy() {
    for dir in /Applications "$HOME/Applications"; do
        if [[ -d "$dir/Pendant.app" ]]; then echo "$dir/Pendant.app"; return 0; fi
    done
    return 0
}
is_ours() {
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null)" == "local.pendant.app" ]]
}
TARGET="$(installed_copy)"
if [[ "$1" == "--install" && -z "$TARGET" ]]; then
    if [[ -w /Applications ]]; then TARGET="/Applications/Pendant.app"
    else mkdir -p "$HOME/Applications"; TARGET="$HOME/Applications/Pendant.app"; fi
fi
if [[ -n "$TARGET" ]]; then
    if [[ -d "$TARGET" ]] && ! is_ours "$TARGET"; then
        echo "Not installing: $TARGET is a different app with the same name."
    else
        rm -rf "$TARGET"
        ditto "$APP" "$TARGET"
        # Keep a single copy, so macOS always opens the one in Applications.
        rm -rf "$APP"
        echo "Installed $TARGET"
    fi
fi
