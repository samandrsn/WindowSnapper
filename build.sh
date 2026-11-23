#!/bin/bash
# Builds WindowSnapper.app into ./build.
#   ./build.sh             build for this Mac
#   ./build.sh --install   build, copy to /Applications and launch
#   ./build.sh --release   universal (Apple Silicon + Intel), ad-hoc signed, zipped for download
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-}"
ARCHS=()
if [[ "$MODE" == "--release" ]]; then ARCHS=(--arch arm64 --arch x86_64); fi

swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/WindowSnapper"

APP=build/WindowSnapper.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WindowSnapper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [[ "$MODE" == "--release" ]]; then
  # Downloads are signed ad hoc so no personal certificate details ship inside the app.
  IDENTITY=""
else
  # Sign with your Apple Development certificate if you have one: macOS ties the Accessibility
  # permission to the signature, so a stable identity means you only grant it once.
  IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
fi
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with: ${IDENTITY:-ad-hoc})"

if [[ "$MODE" == "--install" ]]; then
  pkill -x WindowSnapper 2>/dev/null || true
  rm -rf /Applications/WindowSnapper.app
  cp -R "$APP" /Applications/
  open /Applications/WindowSnapper.app
  echo "Installed to /Applications and launched."
fi

if [[ "$MODE" == "--release" ]]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
  ZIP="build/WindowSnapper.zip"   # same name every release, so the "latest" download link never changes
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
  echo "Release zip for version $VERSION: $ZIP"
fi
