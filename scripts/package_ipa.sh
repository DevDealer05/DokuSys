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
    <key>NSFaceIDUsageDescription</key>
    <string>Face ID wird genutzt, um deine sensiblen Schulden- und Finanzdaten zu schützen</string>
</dict>
</plist>
EOF
fi

if [ -f "dist/Payload/DigitalesBuero.app/Info.plist" ]; then
    PLIST="dist/Payload/DigitalesBuero.app/Info.plist"

    # Permissions
    /usr/libexec/PlistBuddy -c "Add :NSFaceIDUsageDescription string 'Face ID wird genutzt, um deine sensiblen Schulden- und Finanzdaten zu schützen'" "$PLIST" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :NSFaceIDUsageDescription 'Face ID wird genutzt, um deine sensiblen Schulden- und Finanzdaten zu schützen'" "$PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :NSCameraUsageDescription string 'Kamera zum Scannen von Briefen und Belegen'" "$PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :NSPhotoLibraryUsageDescription string 'Fotos zum Dokumenten-Archiv hinzufügen'" "$PLIST" 2>/dev/null || true

    # AppIcon declarations for iOS SpringBoard / Home Screen
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string 'AppIcon60x60'" "$PLIST" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile 'AppIcon60x60'" "$PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string 'AppIcon'" "$PLIST" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconName 'AppIcon'" "$PLIST" 2>/dev/null || true

    # Legacy array
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFiles array" "$PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFiles: string 'AppIcon60x60'" "$PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFiles: string 'AppIcon76x76'" "$PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFiles: string 'AppIcon83.5x83.5'" "$PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFiles: string 'icon'" "$PLIST" 2>/dev/null || true

    # CFBundleIcons (iPhone)
    /usr/libexec/PlistBuddy -c "Add :CFBundleIcons dict" "$PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :CFBundleIcons:CFBundlePrimaryIcon dict" "$PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName string 'AppIcon'" "$PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles array" "$PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles: string 'AppIcon60x60'" "$PLIST" 2>/dev/null || true

    # CFBundleIcons~ipad (iPad)
    /usr/libexec/PlistBuddy -c "Add :CFBundleIcons~ipad dict" "$PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :CFBundleIcons~ipad:CFBundlePrimaryIcon dict" "$PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :CFBundleIcons~ipad:CFBundlePrimaryIcon:CFBundleIconName string 'AppIcon'" "$PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :CFBundleIcons~ipad:CFBundlePrimaryIcon:CFBundleIconFiles array" "$PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :CFBundleIcons~ipad:CFBundlePrimaryIcon:CFBundleIconFiles: string 'AppIcon60x60'" "$PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :CFBundleIcons~ipad:CFBundlePrimaryIcon:CFBundleIconFiles: string 'AppIcon76x76'" "$PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :CFBundleIcons~ipad:CFBundlePrimaryIcon:CFBundleIconFiles: string 'AppIcon83.5x83.5'" "$PLIST" 2>/dev/null || true
fi

# Compile Assets.xcassets to Assets.car if actool is available
if [ -d "Assets.xcassets" ] && xcrun --find actool &>/dev/null; then
    echo "Compiling Assets.car with actool..."
    xcrun actool Assets.xcassets \
        --compile dist/Payload/DigitalesBuero.app \
        --platform iphoneos \
        --minimum-deployment-target 17.0 \
        --app-icon AppIcon \
        --output-partial-info-plist dist/icon_partial.plist 2>/dev/null || true
    if [ -f "dist/icon_partial.plist" ]; then
        /usr/libexec/PlistBuddy -x -c "Merge dist/icon_partial.plist" dist/Payload/DigitalesBuero.app/Info.plist 2>/dev/null || true
    fi
fi

if [ -f "icon.png" ]; then
    echo "Adding all icon resolutions to app bundle..."
    sips -z 120 120 icon.png --out dist/Payload/DigitalesBuero.app/AppIcon60x60@2x.png >/dev/null 2>&1 || cp icon.png dist/Payload/DigitalesBuero.app/AppIcon60x60@2x.png
    sips -z 180 180 icon.png --out dist/Payload/DigitalesBuero.app/AppIcon60x60@3x.png >/dev/null 2>&1 || cp icon.png dist/Payload/DigitalesBuero.app/AppIcon60x60@3x.png
    sips -z 152 152 icon.png --out dist/Payload/DigitalesBuero.app/AppIcon76x76@2x~ipad.png >/dev/null 2>&1 || cp icon.png dist/Payload/DigitalesBuero.app/AppIcon76x76@2x~ipad.png
    sips -z 167 167 icon.png --out dist/Payload/DigitalesBuero.app/AppIcon83.5x83.5@2x~ipad.png >/dev/null 2>&1 || cp icon.png dist/Payload/DigitalesBuero.app/AppIcon83.5x83.5@2x~ipad.png
    sips -z 120 120 icon.png --out dist/Payload/DigitalesBuero.app/AppIcon@2x.png >/dev/null 2>&1 || cp icon.png dist/Payload/DigitalesBuero.app/AppIcon@2x.png
    sips -z 180 180 icon.png --out dist/Payload/DigitalesBuero.app/AppIcon@3x.png >/dev/null 2>&1 || cp icon.png dist/Payload/DigitalesBuero.app/AppIcon@3x.png
    sips -z 60 60 icon.png --out dist/Payload/DigitalesBuero.app/AppIcon.png >/dev/null 2>&1 || cp icon.png dist/Payload/DigitalesBuero.app/AppIcon.png
    sips -z 120 120 icon.png --out dist/Payload/DigitalesBuero.app/Icon-60@2x.png >/dev/null 2>&1 || cp icon.png dist/Payload/DigitalesBuero.app/Icon-60@2x.png
    sips -z 180 180 icon.png --out dist/Payload/DigitalesBuero.app/Icon-60@3x.png >/dev/null 2>&1 || cp icon.png dist/Payload/DigitalesBuero.app/Icon-60@3x.png
    sips -z 120 120 icon.png --out dist/Payload/DigitalesBuero.app/icon@2x.png >/dev/null 2>&1 || cp icon.png dist/Payload/DigitalesBuero.app/icon@2x.png
    sips -z 180 180 icon.png --out dist/Payload/DigitalesBuero.app/icon@3x.png >/dev/null 2>&1 || cp icon.png dist/Payload/DigitalesBuero.app/icon@3x.png
    cp icon.png dist/Payload/DigitalesBuero.app/icon.png
    cp icon.png dist/Payload/DigitalesBuero.app/AppIcon1024x1024.png
fi

echo "Ad-hoc codesigning app bundle..."
codesign --force --deep --sign - dist/Payload/DigitalesBuero.app || true

rm -f DigitalesBuero.ipa
cd dist
zip -qr ../DigitalesBuero.ipa Payload/
cd ..

IPA_SIZE=$(stat -f%z DigitalesBuero.ipa 2>/dev/null || stat -c%s DigitalesBuero.ipa || echo 0)
echo "=== DigitalesBuero.ipa created successfully ($IPA_SIZE bytes) ==="
