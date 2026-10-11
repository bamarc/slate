#!/usr/bin/env bash
# Build an automated, self-contained Slate AppImage:
# 1. Compile release binary (slate-showcase)
# 2. Assemble AppDir structure
# 3. Deploy dynamic dependencies and rpaths via linuxdeploy
# 4. Package into standalone AppImage via appimagetool (using pre-cached runtime)
#
# Usage:
#   just appimage
#   or: bash packaging/appimage/build.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIST="$ROOT/dist"
TOOLS="$ROOT/target/tools"
APPDIR="$DIST/AppDir"
ARCH="${ARCH:-$(uname -m)}"

if [ "$ARCH" != "x86_64" ]; then
    echo "[-] Warning: Current host architecture is $ARCH. Standard toolchains target x86_64."
fi

APPIMAGE_VERSION="${APPIMAGE_VERSION:-$(grep '^version' "$ROOT/Cargo.toml" | head -1 | cut -d'"' -f2)-dev}"
OUT_FILE="Slate-${ARCH}.AppImage"

mkdir -p "$DIST" "$TOOLS"

echo "==> [1/5] Building release binary for slate-showcase..."
cargo build --release -p slate-showcase --manifest-path "$ROOT/Cargo.toml"

echo "==> [2/5] Ensuring packaging toolchain in $TOOLS..."
LINUXDEPLOY="$TOOLS/linuxdeploy-x86_64.AppImage"
if [ ! -x "$LINUXDEPLOY" ]; then
    echo "    Fetching linuxdeploy..."
    curl --connect-timeout 10 --max-time 120 --retry 3 -fL -o "$LINUXDEPLOY" \
        https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage
    chmod +x "$LINUXDEPLOY"
fi

APPIMAGETOOL="$TOOLS/appimagetool-x86_64.AppImage"
if [ ! -x "$APPIMAGETOOL" ]; then
    echo "    Fetching appimagetool..."
    curl --connect-timeout 10 --max-time 120 --retry 3 -fL -o "$APPIMAGETOOL" \
        https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
    chmod +x "$APPIMAGETOOL"
fi

RUNTIME="$TOOLS/runtime-x86_64"
if [ ! -f "$RUNTIME" ]; then
    echo "    Fetching AppImage runtime ($ARCH)..."
    curl --connect-timeout 10 --max-time 120 --retry 3 -fL -o "$RUNTIME" \
        https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-x86_64
fi

if [ ! -f "$ROOT/packaging/slate.png" ] && [ -f "$ROOT/packaging/icon.svg" ]; then
    if command -v convert >/dev/null 2>&1; then
        echo "    Rendering icon from SVG..."
        convert -background none -resize 256x256 "$ROOT/packaging/icon.svg" "$ROOT/packaging/slate.png"
    fi
fi

echo "==> [3/5] Assembling AppDir structure..."
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" \
         "$APPDIR/usr/share/applications" \
         "$APPDIR/usr/share/icons/hicolor/256x256/apps"

cp "$ROOT/target/release/slate-showcase" "$APPDIR/usr/bin/slate-showcase"
ln -sf "slate-showcase" "$APPDIR/usr/bin/slate"

cp "$ROOT/packaging/slate.desktop" "$APPDIR/usr/share/applications/slate.desktop"
if [ -f "$ROOT/packaging/slate.png" ]; then
    cp "$ROOT/packaging/slate.png" "$APPDIR/usr/share/icons/hicolor/256x256/apps/slate.png"
    cp "$ROOT/packaging/slate.png" "$APPDIR/slate.png"
fi

echo "==> [4/5] Running linuxdeploy (dependency bundling and rpath adjustment)..."
export APPIMAGE_EXTRACT_AND_RUN=1
export LINUXDEPLOY_OUTPUT_VERSION="$APPIMAGE_VERSION"

"$LINUXDEPLOY" \
    --appdir "$APPDIR" \
    -e "$APPDIR/usr/bin/slate-showcase" \
    --desktop-file "$APPDIR/usr/share/applications/slate.desktop" \
    --icon-file "$APPDIR/slate.png"

echo "==> [5/5] Generating final AppImage via appimagetool..."
rm -f "$DIST/$OUT_FILE"
"$APPIMAGETOOL" --no-appstream --runtime-file "$RUNTIME" "$APPDIR" "$DIST/$OUT_FILE"
chmod +x "$DIST/$OUT_FILE"

echo "==> Verifying AppImage executable..."
"$DIST/$OUT_FILE" --appimage-version >/dev/null

FILESIZE="$(du -h "$DIST/$OUT_FILE" | cut -f1)"
echo "==> Success! Standalone AppImage generated:"
echo "    Path: $DIST/$OUT_FILE"
echo "    Size: $FILESIZE"
