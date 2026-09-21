#!/bin/zsh
set -e
cd "$(dirname "$0")"

APP="build/Agent Fleet.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc Sources/*.swift \
  -o "$APP/Contents/MacOS/AgentFleet" \
  -target "$(uname -m)-apple-macos14.0" \
  -framework AppKit -framework SwiftUI \
  -O

cp Resources/Info.plist "$APP/Contents/Info.plist"

# The .icns is generated from Resources/icon.png rather than committed, so a
# fresh clone builds without it.
if [ ! -f Resources/AppIcon.icns ] || [ Resources/icon.png -nt Resources/AppIcon.icns ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size Resources/icon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) Resources/icon.png \
      --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
  rm -rf "$(dirname "$ICONSET")"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# A stable signing identity, not ad-hoc. macOS ties Accessibility (and every
# other TCC) grant to code identity, and `--sign -` mints a new one on every
# build — so the permission you granted yesterday silently stopped applying to
# today's binary. Signing with a real identity keeps the grant across rebuilds.
# Set FLEET_SIGN_IDENTITY to pick one; otherwise the first code-signing
# identity in your keychain is used.
IDENTITY="${FLEET_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(.*\)".*/\1/p' | head -1)}"

if [ -n "$IDENTITY" ] && codesign --force --identifier local.notchfleet \
     --sign "$IDENTITY" "$APP" 2>/dev/null; then
  echo "signed as: $IDENTITY"
else
  codesign --force --identifier local.notchfleet --sign - "$APP" >/dev/null 2>&1 || true
  echo "signed ad-hoc — no code-signing identity found in your keychain."
  echo "  Accessibility permission will need re-granting after every build,"
  echo "  because macOS ties it to code identity. A free Apple Development"
  echo "  certificate, or any self-signed one, avoids that."
fi

echo "built: $APP"
