#!/bin/bash
# SideStore apps.json Generator
# Usage: ./scripts/generate_apps_json.sh [path/to/DigitalesBuero.ipa]
set -e

VERSION=$(grep 'displayVersion' Package.swift | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo '1.0')
BUILD=$(grep 'bundleVersion' Package.swift | grep -oE '"[0-9]+"' | tr -d '"' | head -1 || echo '1')
DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
IPA_PATH=${1:-DigitalesBuero.ipa}
IPA_SIZE=$(stat -f%z "$IPA_PATH" 2>/dev/null || stat -c%s "$IPA_PATH" 2>/dev/null || echo 0)

cat > apps.json << EOF
{
  "name": "Digitales Buero Updates",
  "identifier": "de.kim.DigitalesBuero.repo",
  "apps": [{
    "name": "Digitales Buero",
    "bundleIdentifier": "de.kim.DigitalesBuero",
    "developerName": "Kim",
    "subtitle": "Schulden und Haushalt Manager",
    "version": "${VERSION}",
    "versionDate": "${DATE}",
    "versionDescription": "Build ${BUILD} - Automatisch gebaut via GitHub Actions.",
    "downloadURL": "https://DevDealer05.github.io/DokuSys/DigitalesBuero.ipa",
    "localizedDescription": "Digitales Buero - Haushalt, Schulden, Scanner und KI-Assistent.",
    "iconURL": "https://raw.githubusercontent.com/DevDealer05/DokuSys/main/icon.png",
    "tintColor": "6E5BE8",
    "size": ${IPA_SIZE},
    "permissions": [
      {"type": "camera", "usageDescription": "Kamera zum Scannen von Briefen und Belegen"}
    ]
  }],
  "news": []
}
EOF

echo "apps.json generated: v${VERSION} (build ${BUILD}), IPA size: ${IPA_SIZE} bytes"
