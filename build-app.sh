#!/bin/bash
# Builds "Claude Chat.app" from this Swift package, installs it to ~/Applications and opens it.
# Needs Xcode or the Command Line Tools (macOS 14+).
set -euo pipefail
cd "$(dirname "$0")"

echo "Building Claude Chat (release)…"
swift build -c release 2>&1 | tee build.log
BIN="$(swift build -c release --show-bin-path)/ClaudeChat"

APP="build/Claude Chat.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeChat"
cp Resources/AppIcon.icns Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>        <string>ClaudeChat</string>
    <key>CFBundleIdentifier</key>        <string>com.fred.ClaudeChat</string>
    <key>CFBundleName</key>              <string>Claude Chat</string>
    <key>CFBundleDisplayName</key>       <string>Claude Chat</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.1</string>
    <key>CFBundleVersion</key>           <string>2</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS will launch it locally.
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "warning: codesign failed (app may still run)"

# Install to ~/Applications (replacing an older copy) and launch.
mkdir -p "$HOME/Applications"
pkill -x ClaudeChat 2>/dev/null || true
rm -rf "$HOME/Applications/Claude Chat.app"
cp -R "$APP" "$HOME/Applications/"
touch "$HOME/Applications/Claude Chat.app"   # nudge Finder/Dock to pick up the icon
open "$HOME/Applications/Claude Chat.app"

echo ""
echo "Done: Claude Chat is in ~/Applications and running."
echo "Tip: right-click its Dock icon → Options → Keep in Dock."
