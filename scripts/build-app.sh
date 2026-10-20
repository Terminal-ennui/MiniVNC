#!/usr/bin/env bash
# Builds build/MiniVNC.app (release) and code-signs it.
# Signs with $SIGN_IDENTITY, else the first "Apple Development" identity, else ad-hoc.
# A stable identity keeps Keychain "Always Allow" working across rebuilds.
# Optional: VERSION=1.2.3 and BUILD_NUMBER=42 stamp the bundle (the release workflow sets both).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product MiniVNC
binary="$(swift build -c release --show-bin-path)/MiniVNC"

rm -rf build/MiniVNC.app build/AppIcon.iconset
mkdir -p build/MiniVNC.app/Contents/MacOS build/MiniVNC.app/Contents/Resources build/AppIcon.iconset
cp "$binary" build/MiniVNC.app/Contents/MacOS/MiniVNC
cp Resources/Info.plist build/MiniVNC.app/Contents/Info.plist
if [[ -n "${VERSION:-}" ]]; then
  plutil -replace CFBundleShortVersionString -string "$VERSION" build/MiniVNC.app/Contents/Info.plist
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
  plutil -replace CFBundleVersion -string "$BUILD_NUMBER" build/MiniVNC.app/Contents/Info.plist
fi

# App icon: every iconset size from the 1024 px master.
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Resources/AppIcon.png --out "build/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  sips -z "$((size * 2))" "$((size * 2))" Resources/AppIcon.png --out "build/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o build/MiniVNC.app/Contents/Resources/AppIcon.icns

identity="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}"
codesign --force --sign "${identity:--}" build/MiniVNC.app
echo "Built build/MiniVNC.app (signed: ${identity:-ad-hoc})"
