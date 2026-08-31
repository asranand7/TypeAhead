#!/bin/bash
set -e

cd "$(dirname "$0")"

# Builds and installs the input-method front-end.
#
# Separate from build.sh because this is a different kind of thing: an input
# method lives in ~/Library/Input Methods, is registered with the text input
# system, and has to be picked from the Input menu. The menu-bar app keeps
# working whether or not this is installed — they share the memory store.

APP_NAME="TypeAheadIM"
BUNDLE_ID="com.typeahead.inputmethod.TypeAhead"
CONNECTION="TypeAhead_1_Connection"
CONTROLLER="TypeAheadInputController"
INSTALL_DIR="$HOME/Library/Input Methods"
APP_DIR="$APP_NAME.app/Contents"

echo "🔨 Building $APP_NAME..."
swift build -c release --product "$APP_NAME" 2>&1 | tail -2

echo "📦 Creating input method bundle..."
rm -rf "$APP_NAME.app"
mkdir -p "$APP_DIR/MacOS" "$APP_DIR/Resources"

# Three names must agree or the input method fails *silently*: it appears in the
# menu, can be selected, and never receives a keystroke.
#   InputMethodConnectionName        ↔ the name passed to IMKServer in main.swift
#   InputMethodServerControllerClass ↔ the @objc name on the controller class
#   TISInputSourceID                 ↔ the bundle identifier
# Modelled directly on azooKey (dev.ensan.inputmethod.azooKeyMac), a working
# third-party Swift input method, rather than assembled from guesses. Four
# previous attempts failed because of one thing:
#
#   The key inside tsInputModeListKey must be one of Apple's OWN input mode
#   names — "com.apple.inputmethod.Roman" for a Latin-script method. It is not
#   an identifier you invent. Your own id goes in TISInputSourceID, as the
#   value. Using a made-up mode name gives the system nowhere to file the
#   source, so it silently never appears, with no error anywhere.
cat > "$APP_DIR/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>TypeAhead</string>
    <key>CFBundleDisplayName</key>
    <string>TypeAhead</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>English</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSBackgroundOnly</key>
    <true/>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>InputMethodConnectionName</key>
    <string>$CONNECTION</string>
    <key>InputMethodServerControllerClass</key>
    <string>$CONTROLLER</string>
    <key>TISIntendedLanguage</key>
    <string>en</string>
    <key>tsInputMethodCharacterRepertoireKey</key>
    <array>
        <string>Latn</string>
    </array>
    <key>tsInputMethodIconFileKey</key>
    <string>TypeAhead.tiff</string>
    <key>ComponentInputModeDict</key>
    <dict>
        <key>tsInputModeListKey</key>
        <dict>
            <key>com.apple.inputmethod.Roman</key>
            <dict>
                <key>TISIconIsTemplate</key>
                <true/>
                <key>TISInputSourceID</key>
                <string>$BUNDLE_ID.Roman</string>
                <key>TISIntendedLanguage</key>
                <string>en</string>
                <key>tsInputModeAlternateMenuIconFileKey</key>
                <string>TypeAhead.tiff</string>
                <key>tsInputModeDefaultStateKey</key>
                <true/>
                <key>tsInputModeIsVisibleKey</key>
                <true/>
                <key>tsInputModeMenuIconFileKey</key>
                <string>TypeAhead.tiff</string>
                <key>tsInputModePaletteIconFileKey</key>
                <string>TypeAhead.tiff</string>
                <key>tsInputModePrimaryInScriptKey</key>
                <false/>
                <key>tsInputModeScriptKey</key>
                <string>smRoman</string>
            </dict>
        </dict>
        <key>tsVisibleInputModeOrderedArrayKey</key>
        <array>
            <string>com.apple.inputmethod.Roman</string>
        </array>
    </dict>
</dict>
</plist>
PLIST

cp ".build/release/$APP_NAME" "$APP_DIR/MacOS/$APP_NAME"

# The input mode is silently rejected if tsInputModeMenuIconFileKey names a file
# that does not exist — the source never appears, with no error anywhere. This is
# what a shipping input method ships as a .tiff, so do the same.
echo "🎨 Generating menu icon..."
cat > /tmp/typeahead-icon.swift << 'ICONSWIFT'
import AppKit
let size = NSSize(width: 16, height: 16)
let image = NSImage(size: size)
image.lockFocus()
let text = "TA" as NSString
let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
    .foregroundColor: NSColor.black
]
let bounds = text.boundingRect(with: size, attributes: attributes)
text.draw(at: NSPoint(x: (size.width - bounds.width) / 2,
                      y: (size.height - bounds.height) / 2),
          withAttributes: attributes)
image.unlockFocus()
if let tiff = image.tiffRepresentation {
    try? tiff.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
ICONSWIFT
swift /tmp/typeahead-icon.swift "$APP_DIR/Resources/TypeAhead.tiff" 2>/dev/null || true
if [ ! -f "$APP_DIR/Resources/TypeAhead.tiff" ]; then
    echo "⚠️  Icon generation failed; the input source may not appear."
fi

IDENTITY="TypeAhead Self-Signed"
if security find-certificate -c "$IDENTITY" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
    SIGN_AS="$IDENTITY"
else
    SIGN_AS="-"
fi
echo "🔏 Signing..."
xattr -cr "$APP_NAME.app"
codesign --force --sign "$SIGN_AS" "$APP_DIR/MacOS/$APP_NAME"
codesign --force --deep --sign "$SIGN_AS" "$APP_NAME.app"

echo "📍 Installing to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
# A running input method holds the old bundle open; the text input system will
# not notice a replacement underneath it.
pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
sleep 0.5
rm -rf "$INSTALL_DIR/$APP_NAME.app"
cp -R "$APP_NAME.app" "$INSTALL_DIR/"

echo "📣 Registering with the text input system..."
# Launching it once makes the system register the input source, which is
# otherwise not offered until the next login. Fully detached — inheriting this
# script's stdout would keep the script running for as long as the input method
# lives, which is forever.
"$INSTALL_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null 2>&1 &
disown 2>/dev/null || true
sleep 1

echo ""
echo "✅ Installed to $INSTALL_DIR"
echo ""
echo "⚠️  YOU MUST LOG OUT AND BACK IN (or restart) BEFORE IT WILL APPEAR."
echo ""
echo "   macOS builds its list of input sources at login. TISRegisterInputSource"
echo "   reports success for a newly installed bundle, but the source genuinely"
echo "   does not exist until the text input system is rebuilt at the next login."
echo "   There is no supported way to force that from a script."
echo ""
echo "   After logging back in, either:"
echo "     swift run typeahead-enable-im"
echo "   or by hand:"
echo "     System Settings › Keyboard › Text Input › Input Sources › Edit… › +"
echo "     → English → TypeAhead → Add"
echo ""
echo "   Then pick TypeAhead from the input menu in the menu bar (⌃Space cycles)."
echo "   Suggestions then appear INSIDE the text field. Tab accepts."
echo ""
echo "   The menu-bar app keeps working in the meantime, and they share memory."
