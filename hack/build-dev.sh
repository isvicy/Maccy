#!/usr/bin/env bash
# Build Maccy-dev — a sibling install of Maccy with bundle id org.p0deje.Maccy.dev,
# isolated sandbox container, ad-hoc signed (no Apple Developer account needed).
#
# Output: build/dd-dev/Build/Products/Debug/Maccy-dev.app
# Optionally: --install   copies the result to /Applications/Maccy-dev.app

set -euo pipefail

cd "$(dirname "$0")/.."

INSTALL=0
CONFIG=Debug
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --release) CONFIG=Release ;;
    *) echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

DERIVED=build/dd-dev
BUILT_APP="$DERIVED/Build/Products/$CONFIG/Maccy.app"
APP="$DERIVED/Build/Products/$CONFIG/Maccy-dev.app"

mkdir -p build

# PRODUCT_NAME override leaks into SPM package bundles and causes duplicate
# output paths. So we leave PRODUCT_NAME alone (built artifact stays Maccy.app)
# and rename it after the build.
xcodebuild \
  -project Maccy.xcodeproj \
  -scheme Maccy \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  PRODUCT_BUNDLE_IDENTIFIER=org.p0deje.Maccy.dev \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= \
  MACOSX_DEPLOYMENT_TARGET=15.0 \
  build 2>&1 | tail -60

if [[ ! -d "$BUILT_APP" ]]; then
  echo "ERROR: build succeeded but $BUILT_APP missing" >&2
  exit 1
fi

# Rename Maccy.app → Maccy-dev.app. The build already ad-hoc signed everything
# (executable + nested dylib + frameworks) via CODE_SIGN_IDENTITY=- ; do NOT
# re-sign with `codesign --deep` — it breaks the inner Maccy.debug.dylib's
# signature and dyld refuses to load it (team ID mismatch).
rm -rf "$APP"
mv "$BUILT_APP" "$APP"

echo ""
echo "Built: $APP"
codesign -dvv "$APP" 2>&1 | head -8

if (( INSTALL )); then
  if pgrep -x Maccy-dev > /dev/null; then
    echo "killing running Maccy-dev..."
    killall Maccy-dev || true
    sleep 1
  fi
  rm -rf /Applications/Maccy-dev.app
  cp -R "$APP" /Applications/Maccy-dev.app
  echo "Installed: /Applications/Maccy-dev.app"
fi
