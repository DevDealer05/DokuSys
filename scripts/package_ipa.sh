#!/bin/bash
set -e

VERSION="${1:-1.0}"
BUILD="${2:-1}"
COMMIT="${3:-dev}"
DATE="${4:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

echo "=== Packaging DigitalesBuero.ipa (v$VERSION build $BUILD, commit $COMMIT) ==="

rm -rf dist
mkdir -p dist/Payload/DigitalesBuero.app

APP_PATH=$(find build/DerivedData -name "*.app" -type d 2>/dev/null | head -1)
if [ -n "$APP_PATH" ]; then
    echo "Found .app bundle: $APP_PATH"
    cp -R "$APP_PATH/" dist/Payload/DigitalesBuero.app/
else
    echo "Packaging compiled binary into .app bundle"
    BIN=$(find build/DerivedData/Build/Products -name "DigitalesBuero" -type f 2>/dev/null | head -1)
    if [ -z "$BIN" ]; then
        BIN=$(find build/DerivedData/Build/Products -name "AppModule" -type f 2>/dev/null | head -1)
    fi
    if [ -z "$BIN" ]; then
        BIN=$(find build/DerivedData -type f -perm +111 -not -name "*.sh" -not -name "*.py" -not -name "*.dylib" 2>/dev/null | head -1)
    fi

    if [ -z "$BIN" ]; then
        echo "Error: No compiled executable binary found in build/DerivedData"
        exit 1
    fi

    echo "Found executable binary: $BIN"
    cp "$BIN" dist/Payload/DigitalesBuero.app/DigitalesBuero
    chmod +x dist/Payload/DigitalesBuero.app/DigitalesBuero

    cat > dist/Payload/DigitalesBuero.app/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>de.kim.DigitalesBuero</string>
    <key>CFBundleName</key>
    <string>Digitales Buero</string>
    <key>CFBundleDisplayName</key>
    <string>Digitales Buero</string>
    <key>CFBundleExecutable</key>
    <string>DigitalesBuero</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>${BUILD}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>GIT_COMMIT_SHA</key>
    <string>${COMMIT}</string>
    <key>BUILD_DATE</key>
    <string>${DATE}</string>
    <key>MinimumOSVersion</key>
    <string>17.0</string>
    <key>UIRequiredDeviceCapabilities</key>
    <array>
        <string>arm64</string>
    </array>
    <key>UILaunchScreen</key>
    <dict/>
    <key>UISupportedInterfaceOrientations</key>
    <array>
        <string>UIInterfaceOrientationPortrait</string>
    </array>
    <key>NSCameraUsageDescription</key>
    <string>Kamera zum Scannen von Briefen und Belegen</string>
    <key>NSPhotoLibraryUsageDescription</key>
    <string>Fotos zum Dokumenten-Archiv hinzufügen</string>
</dict>
</plist>
EOF
fi

if [ -f "icon.png" ]; then
    echo "Adding app icon to bundle"
    cp icon.png dist/Payload/DigitalesBuero.app/AppIcon60x60@2x.png
    cp icon.png dist/Payload/DigitalesBuero.app/AppIcon76x76@2x~ipad.png
fi

echo "Ad-hoc codesigning app bundle..."
codesign --force --deep --sign - dist/Payload/DigitalesBuero.app || true

rm -f DigitalesBuero.ipa
cd dist
zip -qr ../DigitalesBuero.ipa Payload/
cd ..

IPA_SIZE=$(stat -f%z DigitalesBuero.ipa 2>/dev/null || stat -c%s DigitalesBuero.ipa || echo 0)
echo "=== DigitalesBuero.ipa created successfully ($IPA_SIZE bytes) ==="
