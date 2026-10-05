#!/bin/zsh
# Baut "BC Video.saver" (Universal: arm64 + x86_64) und installiert ihn optional.
#   ./build.sh            -> build/BC Video.saver
#   ./build.sh install    -> zusätzlich nach ~/Library/Screen Savers kopieren
set -euo pipefail

cd "$(dirname "$0")"

NAME="BC Video"
EXECUTABLE="BCVideoSaver"
MIN_MACOS="14.0"
BUILD_DIR="build"
BUNDLE="$BUILD_DIR/$NAME.saver"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

rm -rf "$BUNDLE" "$BUILD_DIR/obj"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources" "$BUILD_DIR/obj"

for ARCH in arm64 x86_64; do
    echo "==> Kompiliere $ARCH"
    xcrun swiftc \
        -sdk "$SDK" \
        -target "$ARCH-apple-macos$MIN_MACOS" \
        -swift-version 5 \
        -O \
        -module-name "$EXECUTABLE" \
        -emit-library \
        -Xlinker -install_name -Xlinker "@rpath/$EXECUTABLE" \
        -framework ScreenSaver -framework AVFoundation -framework AppKit \
        -o "$BUILD_DIR/obj/$EXECUTABLE-$ARCH" \
        Sources/*.swift
done

lipo -create "$BUILD_DIR/obj/$EXECUTABLE-arm64" "$BUILD_DIR/obj/$EXECUTABLE-x86_64" \
    -output "$BUNDLE/Contents/MacOS/$EXECUTABLE"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
cp Resources/thumbnail.png Resources/thumbnail@2x.png "$BUNDLE/Contents/Resources/"

echo "==> Signiere (ad hoc)"
codesign --force --sign - --timestamp=none "$BUNDLE"

echo "==> Fertig: $BUNDLE"

if [[ "${1:-}" == "install" ]]; then
    DEST="$HOME/Library/Screen Savers"
    mkdir -p "$DEST"
    rm -rf "$DEST/$NAME.saver"
    cp -R "$BUNDLE" "$DEST/"
    # Laufende Bildschirmschoner-Prozesse beenden, damit die neue Version geladen wird.
    killall legacyScreenSaver 2>/dev/null || true
    killall legacyScreenSaver-x86_64 2>/dev/null || true
    echo "==> Installiert in $DEST/$NAME.saver"
fi
