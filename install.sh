#!/usr/bin/env bash
#
# Build the app and put it on an iPad that is plugged into this Mac with a cable.
#
#   ./install.sh                     -> installs on whichever iPad is plugged in
#   ./install.sh "Some Other iPad"   -> installs on that iPad (name as shown in Finder)
#
# The iPad must be plugged in, unlocked, and must have said "Trust this computer" once.
# The first time, iOS may ask on the iPad to trust the developer: Settings > General >
# VPN & Device Management > tap the developer entry > Trust.
set -euo pipefail
cd "$(dirname "$0")"

BUILD=build

# Which iPad? The one named on the command line, otherwise whichever iPad is plugged in and
# already trusts this Mac. (First time with a new iPad: run  xcrun devicectl manage pair --device "<name>"
# and tap Trust on the iPad.)
DEVICE="${1:-}"
if [ -z "$DEVICE" ]; then
  # Use the ID (no spaces) of the first iPad that is available or connected.
  DEVICE=$(xcrun devicectl list devices 2>/dev/null \
    | awk '/iPad/ && (/ available/ || / connected/) { for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F-]{36}$/) { print $i; exit } }')
fi
if [ -z "$DEVICE" ]; then
  echo "No iPad is plugged in (or none trusts this Mac yet). Plug one in, unlock it, and try again."
  exit 1
fi

echo "==> Building for iPad"
xcodebuild -project RobotArm.xcodeproj -scheme RobotArm -configuration Debug \
  -destination "generic/platform=iOS" -derivedDataPath "$BUILD" \
  -allowProvisioningUpdates -quiet build

APP="$BUILD/Build/Products/Debug-iphoneos/RobotArm.app"
echo "==> Installing on \"$DEVICE\""
xcrun devicectl device install app --device "$DEVICE" "$APP"

echo "==> Launching"
xcrun devicectl device process launch --device "$DEVICE" com.pivotxp.armcontrol || true
echo "Done. If the app did not open, tap the Robot Arm icon on the iPad."
