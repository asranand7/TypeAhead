#!/bin/bash
set -e

cd "$(dirname "$0")"

APP_NAME="TypeAhead"
BUNDLE_ID="com.typeahead.app"
APP_DIR="$APP_NAME.app/Contents"
MACOS_DIR="$APP_DIR/MacOS"
RESOURCES_DIR="$APP_DIR/Resources"

echo "🧪 Running tests..."
# The suite is a plain executable, not XCTest: XCTest ships with Xcode and this
# machine has only the Command Line Tools.
swift run TypeAheadTests

echo "🔨 Building $APP_NAME (release)..."
swift build -c release --product "$APP_NAME" 2>&1

echo "📦 Creating app bundle..."
rm -rf "$APP_NAME.app"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cat > "$APP_DIR/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>TypeAhead</string>
    <key>CFBundleIdentifier</key>
    <string>com.typeahead.app</string>
    <key>CFBundleName</key>
    <string>TypeAhead</string>
    <key>CFBundleDisplayName</key>
    <string>TypeAhead</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.2.1</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <!-- Menu-bar only: no Dock icon, no main window. -->
    <key>NSContactsUsageDescription</key>
    <string>TypeAhead reads only your own contact card, to offer your email and phone number as suggestions instead of making you type them out. Nothing is sent anywhere, and nothing is suggested until you confirm it.</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

cp ".build/release/$APP_NAME" "$MACOS_DIR/$APP_NAME"

# Signing identity matters more here than in a normal app. The Accessibility
# grant is keyed to the code signature, so an ad-hoc signature — which changes
# on every rebuild — makes macOS forget the permission every single build.
# scripts/make-signing-cert.sh creates a stable self-signed identity; if it has
# been run, use it, and the grant then survives rebuilds.
# Checked with find-certificate, not `find-identity -p codesigning`: a
# self-signed certificate is not trusted, so find-identity reports "0 valid
# identities" even though codesign can use it. Using find-identity here silently
# fell back to ad-hoc on every build, defeating the entire point of the cert.
IDENTITY="TypeAhead Self-Signed"
if security find-certificate -c "$IDENTITY" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
    echo "🔏 Signing with stable identity ($IDENTITY)..."
    SIGN_AS="$IDENTITY"
else
    echo "🔏 Signing ad-hoc — the Accessibility grant will reset on each rebuild."
    echo "   Run scripts/make-signing-cert.sh once to stop that."
    SIGN_AS="-"
fi

xattr -cr "$APP_NAME.app"
codesign --force --sign "$SIGN_AS" "$MACOS_DIR/$APP_NAME"
codesign --force --deep --sign "$SIGN_AS" "$APP_NAME.app"
codesign --verify --deep --strict --verbose=2 "$APP_NAME.app"

echo "📍 Installing to /Applications..."
pkill -f "$APP_NAME\.app/Contents/MacOS/$APP_NAME$" 2>/dev/null || true

# And the model server it spawned. Killing the app alone orphans llama-server —
# it reparents to launchd and keeps port 8177 bound, so the next launch spawns a
# server that cannot bind, exits immediately, and leaves the app holding a dead
# Process while health checks pass against the orphan. The model tier then
# reports itself running and answers nothing.
pkill -f "llama-server.*--port 8177" 2>/dev/null || true
sleep 1

rm -rf "/Applications/$APP_NAME.app"
cp -R "$APP_NAME.app" /Applications/
codesign --verify --deep --strict --verbose=2 "/Applications/$APP_NAME.app"

echo "✅ $APP_NAME.app installed to /Applications/"
echo "🚀 Launching..."
open "/Applications/$APP_NAME.app"
