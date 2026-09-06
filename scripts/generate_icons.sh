#!/bin/bash
set -e

SOURCE="${1:-icon.png}"
ASSET_DIR="Assets.xcassets/AppIcon.appiconset"

mkdir -p "$ASSET_DIR"

echo "Generating AppIcon assets from $SOURCE..."

# Generate all standard iOS icon resolutions
sips -z 40 40 "$SOURCE" --out "$ASSET_DIR/icon_40.png" >/dev/null
sips -z 60 60 "$SOURCE" --out "$ASSET_DIR/icon_60.png" >/dev/null
sips -z 58 58 "$SOURCE" --out "$ASSET_DIR/icon_58.png" >/dev/null
sips -z 87 87 "$SOURCE" --out "$ASSET_DIR/icon_87.png" >/dev/null
sips -z 80 80 "$SOURCE" --out "$ASSET_DIR/icon_80.png" >/dev/null
sips -z 120 120 "$SOURCE" --out "$ASSET_DIR/icon_120.png" >/dev/null
sips -z 180 180 "$SOURCE" --out "$ASSET_DIR/icon_180.png" >/dev/null
sips -z 152 152 "$SOURCE" --out "$ASSET_DIR/icon_152.png" >/dev/null
sips -z 167 167 "$SOURCE" --out "$ASSET_DIR/icon_167.png" >/dev/null
sips -z 1024 1024 "$SOURCE" --out "$ASSET_DIR/icon_1024.png" >/dev/null

cat > "$ASSET_DIR/Contents.json" << 'JSON'
{
  "images": [
    {
      "idiom": "iphone",
      "size": "20x20",
      "scale": "2x",
      "filename": "icon_40.png"
    },
    {
      "idiom": "iphone",
      "size": "20x20",
      "scale": "3x",
      "filename": "icon_60.png"
    },
    {
      "idiom": "iphone",
      "size": "29x29",
      "scale": "2x",
      "filename": "icon_58.png"
    },
    {
      "idiom": "iphone",
      "size": "29x29",
      "scale": "3x",
      "filename": "icon_87.png"
    },
    {
      "idiom": "iphone",
      "size": "40x40",
      "scale": "2x",
      "filename": "icon_80.png"
    },
    {
      "idiom": "iphone",
      "size": "40x40",
      "scale": "3x",
      "filename": "icon_120.png"
    },
    {
      "idiom": "iphone",
      "size": "60x60",
      "scale": "2x",
      "filename": "icon_120.png"
    },
    {
      "idiom": "iphone",
      "size": "60x60",
      "scale": "3x",
      "filename": "icon_180.png"
    },
    {
      "idiom": "ipad",
      "size": "20x20",
      "scale": "2x",
      "filename": "icon_40.png"
    },
    {
      "idiom": "ipad",
      "size": "29x29",
      "scale": "2x",
      "filename": "icon_58.png"
    },
    {
      "idiom": "ipad",
      "size": "40x40",
      "scale": "2x",
      "filename": "icon_80.png"
    },
    {
      "idiom": "ipad",
      "size": "76x76",
      "scale": "2x",
      "filename": "icon_152.png"
    },
    {
      "idiom": "ipad",
      "size": "83.5x83.5",
      "scale": "2x",
      "filename": "icon_167.png"
    },
    {
      "idiom": "ios-marketing",
      "size": "1024x1024",
      "scale": "1x",
      "filename": "icon_1024.png"
    }
  ],
  "info": {
    "version": 1,
    "author": "xcode"
  }
}
JSON

cat > Assets.xcassets/Contents.json << 'JSON'
{
  "info": {
    "version": 1,
    "author": "xcode"
  }
}
JSON

echo "AppIcon assets successfully created in $ASSET_DIR"
