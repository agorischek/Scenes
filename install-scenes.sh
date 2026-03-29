#!/bin/zsh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
APPLICATIONS_DIR="$HOME/Applications"
DERIVED_DATA_DIR="$REPO_DIR/.build/Scenes"
APP_BUILD_PATH="$DERIVED_DATA_DIR/Build/Products/Release/Scenes.app"
APP_INSTALL_PATH="$APPLICATIONS_DIR/Scenes.app"
APP_EXECUTABLE_PATH="$APP_INSTALL_PATH/Contents/MacOS/Scenes"
APP_PROCESS_PATTERN="$APP_INSTALL_PATH/Contents/MacOS/Scenes"

mkdir -p "$APPLICATIONS_DIR"

xcodebuild \
  -project "$REPO_DIR/Scenes.xcodeproj" \
  -scheme Scenes \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  build

osascript -e 'tell application id "dev.umeboshi.Scenes" to quit' >/dev/null 2>&1 || true
sleep 1
pkill -f '/Scenes.app/Contents/MacOS/Scenes' || true
pkill -9 -f '/Library/Developer/Xcode/DerivedData/Scenes-.*/Build/Products/Debug/Scenes.app/Contents/MacOS/Scenes' || true
rm -rf "$APP_INSTALL_PATH"
ditto "$APP_BUILD_PATH" "$APP_INSTALL_PATH"
"$APP_EXECUTABLE_PATH" >/dev/null 2>&1 &

for _ in {1..20}; do
  if pgrep -f "$APP_PROCESS_PATTERN" >/dev/null 2>&1; then
    echo "Installed Scenes.app to:"
    echo "  $APP_INSTALL_PATH"
    exit 0
  fi

  sleep 0.25
done

echo "Failed to launch installed Scenes.app at:"
echo "  $APP_INSTALL_PATH" >&2
exit 1
