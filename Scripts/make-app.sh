#!/usr/bin/env bash
# Build build/Earmark.app. Signs with the first "Apple Development" identity so the
# audio capture permission survives rebuilds; falls back to ad-hoc (re-prompts each build).
#   ./Scripts/make-app.sh && open build/Earmark.app
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Soundctl"
APP="build/Earmark.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Soundctl"
cp Scripts/Info.plist "$APP/Contents/Info.plist"

IDENTITY="$(security find-identity -p codesigning -v | awk -F'"' '/Apple Development/ {print $2; exit}')"
codesign --force --timestamp=none --sign "${IDENTITY:--}" "$APP"
echo "built $APP (signed: ${IDENTITY:-ad-hoc})"
