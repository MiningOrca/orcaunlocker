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
# Build universal binaries.
#
# SwiftPM's multi-architecture build path currently depends on Xcode's
# build system. Build the two macOS slices independently instead, then
# combine them with lipo. This keeps the release build working with the
# standalone Swift/Command Line Tools setup as well.
#

BUILD_TMP="$(mktemp -d "${TMPDIR:-/tmp}/orcaunlocker-build.XXXXXX")"

cleanup() {
  rm -rf "$BUILD_TMP"
  if [[ -n "${ICONSET:-}" ]]; then
    rm -rf "$ICONSET"
  fi
}
trap cleanup EXIT

require_universal() {
  local path="$1"
  local label="$2"
  local archs

  if [[ ! -f "$path" ]]; then
    echo "$label is missing: $path" >&2
    exit 1
  fi

  archs="$(/usr/bin/lipo -archs "$path" 2>/dev/null)" || {
    echo "$label is not a Mach-O universal binary: $path" >&2
    exit 1
  }

  if [[ " $archs " != *" arm64 "* || " $archs " != *" x86_64 "* ]]; then
    echo "$label is not universal arm64+x86_64: $archs" >&2
    exit 1
  fi

  echo "[build-app] $label architectures: $archs"
}

find_rustup() {
  if command -v rustup >/dev/null 2>&1; then
    command -v rustup
    return 0
  fi

  if command -v brew >/dev/null 2>&1; then
    local prefix
    prefix="$(brew --prefix rustup 2>/dev/null || true)"
    if [[ -n "$prefix" && -x "$prefix/bin/rustup" ]]; then
      echo "$prefix/bin/rustup"
      return 0
    fi
  fi

  return 1
}

build_universal_helper() {
  # Keep the existing helper build script as the authoritative native build.
  "$ROOT/scripts/build-helper.sh"

  local native_helper="$ROOT/helper/target/release/miningorca-steam-helper"
  local output="$BUILD_TMP/miningorca-steam-helper"
  local native_archs missing_target cross_helper

  if [[ ! -x "$native_helper" ]]; then
    echo "Steam helper is missing: $native_helper" >&2
    exit 1
  fi

  native_archs="$(/usr/bin/lipo -archs "$native_helper" 2>/dev/null)" || {
    echo "Steam helper is not a Mach-O executable: $native_helper" >&2
    exit 1
  }

  if [[ " $native_archs " == *" arm64 "* && " $native_archs " == *" x86_64 "* ]]; then
    cp "$native_helper" "$output"
    chmod +x "$output"
    HELPER_EXECUTABLE="$output"
    require_universal "$HELPER_EXECUTABLE" "Steam helper"
    return 0
  fi

  case "$native_archs" in
    *arm64*)
      missing_target="x86_64-apple-darwin"
      ;;
    *x86_64*)
      missing_target="aarch64-apple-darwin"
      ;;
    *)
      echo "Unexpected Steam helper architecture: $native_archs" >&2
      exit 1
      ;;
  esac

  local rustup_bin=""
  local rust_toolchain="${ORCAUNLOCKER_RUST_TOOLCHAIN:-stable}"
  local toolchain_cargo=""
  local toolchain_rustc=""
  local toolchain_bin=""
  local target_libdir=""

  if rustup_bin="$(find_rustup)"; then
    echo "[build-app] Ensuring Rust toolchain '$rust_toolchain' and target '$missing_target'..."
    "$rustup_bin" toolchain install "$rust_toolchain" --profile minimal >/dev/null
    "$rustup_bin" target add --toolchain "$rust_toolchain" "$missing_target" >/dev/null

    # Do not use `rustup run ... cargo` here. With Homebrew's keg-only rustup
    # and a separate Homebrew `rust` installation, `cargo` can still resolve
    # to the system Cargo/Rust compiler pair. That compiler does not see the
    # stdlib installed into rustup's toolchain and fails with E0463.
    # Resolve the toolchain binaries explicitly and force Cargo to use the
    # matching rustc.
    toolchain_cargo="$("$rustup_bin" which --toolchain "$rust_toolchain" cargo)"
    toolchain_rustc="$("$rustup_bin" which --toolchain "$rust_toolchain" rustc)"
    toolchain_bin="$(dirname "$toolchain_cargo")"

    if [[ ! -x "$toolchain_cargo" || ! -x "$toolchain_rustc" ]]; then
      echo "Unable to resolve Rust toolchain binaries for '$rust_toolchain'." >&2
      exit 1
    fi

    target_libdir="$("$toolchain_rustc" --print target-libdir --target "$missing_target")"
    if [[ ! -d "$target_libdir" ]]; then
      echo "Rust target stdlib is still missing after rustup target add: $missing_target" >&2
      echo "Expected target libdir: $target_libdir" >&2
      exit 1
    fi
  else
    # Homebrew's `rust` formula does not ship additional target stdlibs.
    # Fail before the expensive Swift builds instead of letting cargo emit a
    # long series of E0463 errors.
    cat >&2 <<EOF
Rust target '$missing_target' is required to build the universal Steam helper,
but rustup is not installed.

Install rustup once and rerun the build:

  brew install rustup

The build script will discover Homebrew's keg-only rustup automatically and
install the required Rust target. It will not replace your system Rust setup.
EOF
    exit 1
  fi

  echo "[build-app] Building Steam helper for $missing_target..."

  local -a cargo_args=(
    build
    --manifest-path "$ROOT/helper/Cargo.toml"
    --release
    --target "$missing_target"
  )

  if [[ -f "$ROOT/helper/Cargo.lock" ]]; then
    cargo_args+=(--locked)
  fi

  PATH="$toolchain_bin:$PATH" \
  RUSTC="$toolchain_rustc" \
    "$toolchain_cargo" "${cargo_args[@]}"

  cross_helper="$ROOT/helper/target/$missing_target/release/miningorca-steam-helper"

  if [[ ! -x "$cross_helper" ]]; then
    echo "Cross-compiled Steam helper is missing: $cross_helper" >&2
    exit 1
  fi

  /usr/bin/lipo \
    -create \
    "$native_helper" \
    "$cross_helper" \
    -output "$output"

  chmod +x "$output"
  HELPER_EXECUTABLE="$output"
  require_universal "$HELPER_EXECUTABLE" "Steam helper"
}

build_swift_slice() {
  local triple="$1"
  local scratch="$2"

  echo "[build-app] Building OrcaUnlockerApp for $triple..." >&2

  swift build \
    -c release \
    --triple "$triple" \
    --scratch-path "$scratch" \
    --product OrcaUnlockerApp >&2

  swift build \
    -c release \
    --triple "$triple" \
    --scratch-path "$scratch" \
    --show-bin-path
}

# Build/validate the helper first. If the Rust cross target is unavailable,
# fail immediately instead of spending two minutes building both Swift slices.
build_universal_helper

SWIFT_ARM64_SCRATCH="$BUILD_TMP/swift-arm64"
SWIFT_X86_64_SCRATCH="$BUILD_TMP/swift-x86_64"

ARM64_BIN_DIR="$(build_swift_slice arm64-apple-macosx "$SWIFT_ARM64_SCRATCH")"
X86_64_BIN_DIR="$(build_swift_slice x86_64-apple-macosx "$SWIFT_X86_64_SCRATCH")"

ARM64_APP_EXECUTABLE="$ARM64_BIN_DIR/OrcaUnlockerApp"
X86_64_APP_EXECUTABLE="$X86_64_BIN_DIR/OrcaUnlockerApp"
APP_EXECUTABLE="$BUILD_TMP/OrcaUnlockerApp"

if [[ ! -x "$ARM64_APP_EXECUTABLE" ]]; then
  echo "arm64 app executable is missing: $ARM64_APP_EXECUTABLE" >&2
  exit 1
fi

if [[ ! -x "$X86_64_APP_EXECUTABLE" ]]; then
  echo "x86_64 app executable is missing: $X86_64_APP_EXECUTABLE" >&2
  exit 1
fi

/usr/bin/lipo \
  -create \
  "$ARM64_APP_EXECUTABLE" \
  "$X86_64_APP_EXECUTABLE" \
  -output "$APP_EXECUTABLE"

chmod +x "$APP_EXECUTABLE"
require_universal "$APP_EXECUTABLE" "Orca Unlocker launcher"

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
# Verify final packaged architectures before signing.
#

require_universal "$APP/Contents/MacOS/OrcaUnlocker" "Packaged Orca Unlocker launcher"
require_universal "$APP/Contents/MacOS/miningorca-steam-helper" "Packaged Steam helper"

RUNTIME_DYLIB_COUNT=0
for runtime_dylib in "$APP/Contents/Resources/Runtime/"*.dylib; do
  if [[ ! -f "$runtime_dylib" ]]; then
    continue
  fi
  RUNTIME_DYLIB_COUNT=$((RUNTIME_DYLIB_COUNT + 1))
  require_universal "$runtime_dylib" "Runtime $(basename "$runtime_dylib")"
done

if [[ "$RUNTIME_DYLIB_COUNT" -eq 0 ]]; then
  echo "No runtime dylibs were packaged." >&2
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
  --all-architectures \
  --verbose=2 \
  "$APP/Contents/MacOS/miningorca-steam-helper"

/usr/bin/codesign \
  --verify \
  --strict \
  --all-architectures \
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