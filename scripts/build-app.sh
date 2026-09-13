#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME_DIR="${1:-${ORCAUNLOCKER_RUNTIME_DIR:-}}"

LICENSE_SOURCE="$ROOT/LICENSE.md"
MINESHAFT_NOTICE_SOURCE="$ROOT/docs/legal/MINESHAFT-NOTICE.txt"

DIST_DIR="$ROOT/dist"
APP_NAME="Orca Unlocker"
APP="$DIST_DIR/$APP_NAME.app"
ZIP="$DIST_DIR/Orca-Unlocker-macOS.zip"

VERSION="${ORCAUNLOCKER_VERSION:-0.1.0}"
BUILD_NUMBER="${ORCAUNLOCKER_BUILD:-1}"
BUNDLE_ID="${ORCAUNLOCKER_BUNDLE_ID:-com.orcaunlocker.app}"

ICON_SOURCE="${ORCAUNLOCKER_ICON:-$ROOT/icons/orca_icon.png}"
ICON_NAME="OrcaUnlocker.icns"

BANNER_SOURCE="$ROOT/icons/orca_banner.png"
BANNER_NAME="orca_banner.png"

DEFAULT_SETTINGS_SOURCE="$ROOT/Sources/MiningOrcaLauncherCore/Resources/default-settings.json"

#
# Validate inputs.
#

if [[ -z "$RUNTIME_DIR" ]]; then
  echo "Usage: $0 /path/to/runtime" >&2
  echo "       ORCAUNLOCKER_RUNTIME_DIR=/path/to/runtime $0" >&2
  exit 2
fi

RUNTIME_DIR="$(cd "$RUNTIME_DIR" 2>/dev/null && pwd)" || {
  echo "Runtime directory does not exist: $RUNTIME_DIR" >&2
  exit 1
}

if [[ ! -f "$LICENSE_SOURCE" ]]; then
  echo "License is missing: $LICENSE_SOURCE" >&2
  exit 1
fi

if [[ ! -f "$MINESHAFT_NOTICE_SOURCE" ]]; then
  echo "Mineshaft notice is missing: $MINESHAFT_NOTICE_SOURCE" >&2
  exit 1
fi

if [[ ! -f "$RUNTIME_DIR/manifest.json" ]]; then
  echo "Runtime manifest is missing: $RUNTIME_DIR/manifest.json" >&2
  exit 1
fi

if [[ ! -f "$ICON_SOURCE" ]]; then
  echo "App icon is missing: $ICON_SOURCE" >&2
  exit 1
fi

if [[ ! -f "$BANNER_SOURCE" ]]; then
  echo "Banner artwork is missing: $BANNER_SOURCE" >&2
  exit 1
fi

if [[ ! -f "$DEFAULT_SETTINGS_SOURCE" ]]; then
  echo "Default settings are missing: $DEFAULT_SETTINGS_SOURCE" >&2
  exit 1
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?([.-][A-Za-z0-9]+)*$ ]]; then
  echo "Invalid ORCAUNLOCKER_VERSION: $VERSION" >&2
  exit 2
fi

if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Invalid ORCAUNLOCKER_BUILD: $BUILD_NUMBER" >&2
  exit 2
fi

if [[ ! "$BUNDLE_ID" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "Invalid ORCAUNLOCKER_BUNDLE_ID: $BUNDLE_ID" >&2
  exit 2
fi

cd "$ROOT"

#
# Build binaries.
#

"$ROOT/scripts/build-helper.sh"

swift build \
  -c release \
  --product OrcaUnlockerApp

BIN_DIR="$(swift build -c release --show-bin-path)"

APP_EXECUTABLE="$BIN_DIR/OrcaUnlockerApp"
HELPER_EXECUTABLE="$ROOT/helper/target/release/miningorca-steam-helper"

if [[ ! -x "$APP_EXECUTABLE" ]]; then
  echo "App executable is missing: $APP_EXECUTABLE" >&2
  exit 1
fi

if [[ ! -x "$HELPER_EXECUTABLE" ]]; then
  echo "Steam helper is missing: $HELPER_EXECUTABLE" >&2
  exit 1
fi

#
# Prepare application bundle.
#

ICONSET="$DIST_DIR/OrcaUnlocker.iconset"

rm -rf \
  "$APP" \
  "$ZIP" \
  "$ICONSET"

mkdir -p \
  "$APP/Contents/MacOS" \
  "$APP/Contents/Resources/Runtime" \
  "$APP/Contents/Resources/Licenses" \
  "$ICONSET"

#
# Generate application icon.
#

make_icon() {
  local pixels="$1"
  local filename="$2"

  /usr/bin/sips \
    -s format png \
    -z "$pixels" "$pixels" \
    "$ICON_SOURCE" \
    --out "$ICONSET/$filename" >/dev/null
}

make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
make_icon 32 icon_32x32.png
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png

/usr/bin/iconutil \
  -c icns \
  "$ICONSET" \
  -o "$APP/Contents/Resources/$ICON_NAME"

rm -rf "$ICONSET"

#
# Install application files.
#

cp \
  "$APP_EXECUTABLE" \
  "$APP/Contents/MacOS/OrcaUnlocker"

cp \
  "$LICENSE_SOURCE" \
  "$APP/Contents/Resources/Licenses/OrcaUnlocker-LICENSE.md"

cp \
  "$MINESHAFT_NOTICE_SOURCE" \
  "$APP/Contents/Resources/Licenses/Mineshaft-NOTICE.txt"

cp \
  "$HELPER_EXECUTABLE" \
  "$APP/Contents/MacOS/miningorca-steam-helper"

# Packaged application resources are loaded through Bundle.main.
cp \
  "$DEFAULT_SETTINGS_SOURCE" \
  "$APP/Contents/Resources/default-settings.json"

cp \
  "$BANNER_SOURCE" \
  "$APP/Contents/Resources/$BANNER_NAME"

# Runtime artifacts must remain byte-for-byte identical to the
# Mineshaft release because manifest hashes describe these files.
cp -R \
  "$RUNTIME_DIR/." \
  "$APP/Contents/Resources/Runtime/"

#
# Info.plist.
#

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>Orca Unlocker</string>

    <key>CFBundleExecutable</key>
    <string>OrcaUnlocker</string>

    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>

    <key>CFBundleIconFile</key>
    <string>$ICON_NAME</string>

    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>

    <key>CFBundleName</key>
    <string>Orca Unlocker</string>

    <key>CFBundlePackageType</key>
    <string>APPL</string>

    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>

    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>

    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>

    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 MiningOrca</string>

    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>

    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

chmod +x \
  "$APP/Contents/MacOS/OrcaUnlocker" \
  "$APP/Contents/MacOS/miningorca-steam-helper"

#
# Validate packaged resources before signing.
#

/usr/bin/plutil \
  -lint \
  "$APP/Contents/Info.plist" >/dev/null

if [[ ! -f "$APP/Contents/Resources/default-settings.json" ]]; then
  echo "Packaged default-settings.json is missing." >&2
  exit 1
fi

if [[ ! -f "$APP/Contents/Resources/$BANNER_NAME" ]]; then
  echo "Packaged banner is missing." >&2
  exit 1
fi

if [[ ! -f "$APP/Contents/Resources/Runtime/manifest.json" ]]; then
  echo "Packaged runtime manifest is missing." >&2
  exit 1
fi

if [[ ! -f "$APP/Contents/Resources/Licenses/OrcaUnlocker-LICENSE.md" ]]; then
  echo "Packaged Orca Unlocker license is missing." >&2
  exit 1
fi

if [[ ! -f "$APP/Contents/Resources/Licenses/Mineshaft-NOTICE.txt" ]]; then
  echo "Packaged Mineshaft notice is missing." >&2
  exit 1
fi

#
# Runtime artifacts are copied byte-for-byte because manifest hashes
# describe those exact files.
#
# Do not sign or otherwise mutate runtime dylibs here.
#

/usr/bin/codesign \
  --force \
  --sign - \
  "$APP/Contents/MacOS/miningorca-steam-helper"

#
# Sign and seal the application.
#

/usr/bin/codesign \
  --force \
  --sign - \
  "$APP"

#
# Verify final bundle.
#

/usr/bin/codesign \
  --verify \
  --strict \
  --verbose=2 \
  "$APP"

#
# Package ZIP.
#

/usr/bin/ditto \
  -c -k \
  --sequesterRsrc \
  --keepParent \
  "$APP" \
  "$ZIP"

/usr/bin/unzip \
  -tq \
  "$ZIP"

echo
echo "App:     $APP"
echo "ZIP:     $ZIP"
echo "Version: $VERSION"
echo "Build:   $BUILD_NUMBER"