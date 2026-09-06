#!/bin/bash
# SideStore apps.json Generator
# Usage: ./scripts/generate_apps_json.sh [path/to/DigitalesBuero.ipa]
set -e

VERSION=$(grep 'displayVersion' Package.swift | sed -n 's/.*displayVersion: *"\([^"]*\)".*/\1/p' || echo '1.0.1')
BUILD=$(grep 'bundleVersion' Package.swift | grep -oE '"[0-9]+"' | tr -d '"' | head -1 || echo '2')
DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
IPA_PATH=${1:-DigitalesBuero.ipa}
IPA_SIZE=$(stat -f%z "$IPA_PATH" 2>/dev/null || stat -c%s "$IPA_PATH" 2>/dev/null || echo 0)

COMMIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "latest")
COMMIT_MSG=$(git log -1 --pretty=%B 2>/dev/null | head -n 3 | tr '\n' ' ' | sed 's/"/\\"/g' | sed 's/^[ \t]*//;s/[ \t]*$//' || echo "Update")
if [ -z "$COMMIT_MSG" ]; then COMMIT_MSG="Build ${BUILD} – Update"; fi

cat > apps.json << EOF
{
  "name": "Digitales Buero Updates",
  "identifier": "de.kim.DigitalesBuero.repo",
  "apps": [{
    "name": "Digitales Buero",
    "bundleIdentifier": "de.kim.DigitalesBuero",
    "developerName": "Kim",
    "subtitle": "Schulden, Dokumente & Finanzen",
    "version": "${VERSION}",
    "versionDate": "${DATE}",
    "versionDescription": "v${VERSION} (Build ${BUILD}, ${COMMIT_HASH}): ${COMMIT_MSG}",
    "downloadURL": "https://DevDealer05.github.io/DokuSys/DigitalesBuero.ipa",
    "localizedDescription": "Digitales Buero – Einzelnutzung, Modernes Dokumenten-Management (DMS 2.0), Commercial-Modus & KI-Assistent.",
    "iconURL": "https://raw.githubusercontent.com/DevDealer05/DokuSys/main/icon.png",
    "tintColor": "6E5BE8",
    "size": ${IPA_SIZE},
    "permissions": [
      {"type": "camera", "usageDescription": "Kamera zum Scannen von Briefen und Belegen"},
      {"type": "photos", "usageDescription": "Fotos zum Dokumenten-Archiv hinzufügen"},
      {"type": "faceid", "usageDescription": "Face ID wird genutzt, um deine sensiblen Schulden- und Finanzdaten zu schützen"}
    ]
  }],
  "news": [{
    "title": "Digitales Buero v${VERSION} (Build ${BUILD})",
    "identifier": "release-${BUILD}-${COMMIT_HASH}",
    "caption": "${COMMIT_MSG}",
    "date": "${DATE}",
    "tintColor": "6E5BE8"
  }]
}
EOF

cat > build_info.json << EOF
{
  "appName": "Digitales Buero",
  "bundleIdentifier": "de.kim.DigitalesBuero",
  "version": "${VERSION}",
  "build": "${BUILD}",
  "commit": "${COMMIT_HASH}",
  "buildDate": "${DATE}",
  "ipaSize": ${IPA_SIZE},
  "changeLog": "${COMMIT_MSG}",
  "repo": "DevDealer05/DokuSys",
  "downloadURL": "https://DevDealer05.github.io/DokuSys/DigitalesBuero.ipa",
  "sideStoreRepo": "https://DevDealer05.github.io/DokuSys/apps.json"
}
EOF

echo "apps.json and build_info.json generated: v${VERSION} (build ${BUILD}), IPA size: ${IPA_SIZE} bytes"
