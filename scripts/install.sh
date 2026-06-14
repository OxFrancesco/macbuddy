#!/bin/zsh
# Build MacBuddy (Release) and install it to /Applications.
#
# Why this exists: the App Management permission (needed to write icons onto
# other app bundles) is keyed by macOS to the app's code-signing identity.
# The project signs with a real Apple Development certificate so the identity
# is stable across rebuilds — but only if a single canonical copy is launched.
# This script keeps /Applications/MacBuddy.app as that copy.
set -euo pipefail

cd "$(dirname "$0")/.."

xcodegen generate
xcodebuild -project MacBuddy.xcodeproj -scheme MacBuddy \
  -configuration Release -derivedDataPath build build | tail -2

APP="build/Build/Products/Release/MacBuddy.app"
codesign --verify --strict "$APP"

pkill -x MacBuddy 2>/dev/null && sleep 1 || true
rm -rf /Applications/MacBuddy.app
ditto --noextattr --noqtn "$APP" /Applications/MacBuddy.app

# Do not apply a Finder custom icon here. That writes FinderInfo/resource-fork
# metadata into the app bundle after signing, which makes strict code-signing
# validation fail and can prevent Launch Services from starting the app.

open /Applications/MacBuddy.app

echo "Installed and relaunched /Applications/MacBuddy.app"
