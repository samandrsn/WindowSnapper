#!/bin/bash
# Builds WindowSnapper.app into ./build. Pass --install to copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/WindowSnapper"

APP=build/WindowSnapper.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WindowSnapper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign with your Apple Development certificate if you have one: macOS ties the Accessibility
# permission to the signature, so a stable identity means you only grant it once.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with: ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x WindowSnapper 2>/dev/null || true
  rm -rf /Applications/WindowSnapper.app
  cp -R "$APP" /Applications/
  open /Applications/WindowSnapper.app
  echo "Installed to /Applications and launched."
fi
