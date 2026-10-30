#!/bin/bash
#
# Builds Saathi.app without Xcode, using Apple's free Command Line Tools.
#
#   One-time setup:   xcode-select --install
#   Build and run:    ./build-saathi.sh
#
# The app is installed to ~/Applications/Saathi.app and signed with a local
# "Saathi Dev" certificate (created automatically), so permissions survive rebuilds.
#

set -euo pipefail
cd "$(dirname "$0")"

echo "▸ macOS $(sw_vers -productVersion)"
if ! command -v swift >/dev/null 2>&1; then
    echo "✗ Swift not found. Run:  xcode-select --install   then try again."
    exit 1
fi
swift --version 2>&1 | head -1

echo "▸ Compiling (first build takes a few minutes)…"
swift build -c release --product Saathi
BINARY_PATH="$(swift build -c release --show-bin-path)/Saathi"

# Assembled outside the Desktop: iCloud-synced folders add Finder metadata
# that codesign refuses ("resource fork, Finder information … not allowed").
mkdir -p "$HOME/Applications"
APP_PATH="$HOME/Applications/Saathi.app"
echo "▸ Packaging $APP_PATH"
pkill -x Saathi 2>/dev/null || true
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BINARY_PATH" "$APP_PATH/Contents/MacOS/Saathi"

cat > "$APP_PATH/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>Saathi</string>
	<key>CFBundleIdentifier</key>
	<string>com.ishaangupta.saathi</string>
	<key>CFBundleName</key>
	<string>Saathi</string>
	<key>CFBundleDisplayName</key>
	<string>Saathi</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.2</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>VoiceTranscriptionProvider</key>
	<string>apple</string>
	<key>NSMicrophoneUsageDescription</key>
	<string>Saathi uses your microphone so you can talk to it</string>
	<key>NSSpeechRecognitionUsageDescription</key>
	<string>Saathi uses on-device speech recognition to understand what you say</string>
	<key>NSScreenCaptureUsageDescription</key>
	<string>Saathi needs screen recording access to see your screen when you press the hotkey.</string>
	<key>NSDesktopFolderUsageDescription</key>
	<string>Saathi reads its .env settings file from the project folder.</string>
</dict>
</plist>
PLIST

# App icon from the asset catalog PNGs (iconutil ships with macOS).
ICON_SOURCE_FOLDER="leanring-buddy/Assets.xcassets/AppIcon.appiconset"
if [ -f "$ICON_SOURCE_FOLDER/1024-mac.png" ] && command -v iconutil >/dev/null 2>&1; then
    ICONSET_FOLDER="$(mktemp -d)/AppIcon.iconset"
    rm -rf "$ICONSET_FOLDER" && mkdir -p "$ICONSET_FOLDER"
    cp "$ICON_SOURCE_FOLDER/16-mac.png"   "$ICONSET_FOLDER/icon_16x16.png"
    cp "$ICON_SOURCE_FOLDER/32-mac.png"   "$ICONSET_FOLDER/icon_16x16@2x.png"
    cp "$ICON_SOURCE_FOLDER/32-mac.png"   "$ICONSET_FOLDER/icon_32x32.png"
    cp "$ICON_SOURCE_FOLDER/64-mac.png"   "$ICONSET_FOLDER/icon_32x32@2x.png"
    cp "$ICON_SOURCE_FOLDER/128-mac.png"  "$ICONSET_FOLDER/icon_128x128.png"
    cp "$ICON_SOURCE_FOLDER/256-mac.png"  "$ICONSET_FOLDER/icon_128x128@2x.png"
    cp "$ICON_SOURCE_FOLDER/256-mac.png"  "$ICONSET_FOLDER/icon_256x256.png"
    cp "$ICON_SOURCE_FOLDER/512-mac.png"  "$ICONSET_FOLDER/icon_256x256@2x.png"
    cp "$ICON_SOURCE_FOLDER/512-mac.png"  "$ICONSET_FOLDER/icon_512x512.png"
    cp "$ICON_SOURCE_FOLDER/1024-mac.png" "$ICONSET_FOLDER/icon_512x512@2x.png"
    iconutil -c icns "$ICONSET_FOLDER" -o "$APP_PATH/Contents/Resources/AppIcon.icns" || true
fi

# Signing. macOS ties permissions (Accessibility, Screen Recording…) to the
# app's signature. An ad-hoc signature changes on every build, so permissions
# would reset each time. A self-signed "Saathi Dev" certificate in your login
# keychain keeps the signature stable, so permissions survive rebuilds.
# This script creates that certificate automatically the first time.
find_saathi_signing_identity() {
    security find-identity -p codesigning 2>/dev/null | grep '"Saathi Dev"' | head -1 | awk '{print $2}'
}

SIGNING_IDENTITY_HASH="$(find_saathi_signing_identity)"
if [ -z "$SIGNING_IDENTITY_HASH" ]; then
    echo "▸ Creating the \"Saathi Dev\" signing certificate (one time)…"
    CERTIFICATE_WORK_FOLDER="$(mktemp -d)"
    cat > "$CERTIFICATE_WORK_FOLDER/saathi.cnf" <<'CNF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=Saathi Dev
[ext]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
CNF
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$CERTIFICATE_WORK_FOLDER/saathi.key" -out "$CERTIFICATE_WORK_FOLDER/saathi.crt" \
        -config "$CERTIFICATE_WORK_FOLDER/saathi.cnf" >/dev/null 2>&1
    /usr/bin/openssl pkcs12 -export -name "Saathi Dev" \
        -inkey "$CERTIFICATE_WORK_FOLDER/saathi.key" -in "$CERTIFICATE_WORK_FOLDER/saathi.crt" \
        -out "$CERTIFICATE_WORK_FOLDER/saathi.p12" -passout pass:saathi >/dev/null 2>&1
    security import "$CERTIFICATE_WORK_FOLDER/saathi.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
        -P saathi -T /usr/bin/codesign >/dev/null 2>&1 || true
    rm -rf "$CERTIFICATE_WORK_FOLDER"
    SIGNING_IDENTITY_HASH="$(find_saathi_signing_identity)"
fi

xattr -cr "$APP_PATH"
if [ -n "$SIGNING_IDENTITY_HASH" ] && codesign --force --sign "$SIGNING_IDENTITY_HASH" \
        --entitlements leanring-buddy/leanring-buddy.entitlements "$APP_PATH" 2>/dev/null; then
    echo "▸ Signed with \"Saathi Dev\" — permissions carry over between builds"
else
    echo "▸ Couldn't use \"Saathi Dev\", signing ad-hoc instead"
    codesign --force --sign - --entitlements leanring-buddy/leanring-buddy.entitlements "$APP_PATH"
    # Each ad-hoc build is a new app to macOS, so clear the old build's
    # permission entries; otherwise stale switches show "on" but don't apply.
    for permissionService in Accessibility ScreenCapture ListenEvent PostEvent Microphone SpeechRecognition; do
        tccutil reset "$permissionService" com.ishaangupta.saathi >/dev/null 2>&1 || true
    done
    echo "  Permissions were reset for this build: grant them again, then quit and reopen Saathi."
fi

echo "✓ Built $APP_PATH — opening it now. Look for the ring in your menu bar."
echo "  Reopen any time with:  open ~/Applications/Saathi.app"
open "$APP_PATH"
