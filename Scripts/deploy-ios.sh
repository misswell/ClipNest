#!/usr/bin/env bash
# Build ClipNest for a connected iPhone/iPad, then install and launch it.
#
#   Scripts/deploy-ios.sh              # auto-pick the first paired device
#   Scripts/deploy-ios.sh <UDID>       # target a specific device
#
# Why the explicit signing overrides: `project.yml` pins the iphoneos SDK to the
# upstream author's manual App Store setup (team GU9WTSTX9M, profile "ClipNest
# AppStore"), which cannot sign a local development build. Command-line settings
# win over per-SDK conditional ones, so overriding here signs for our own team and
# leaves the checked-in project (and the upstream archive flow) untouched.
set -euo pipefail

TEAM="${TEAM:-U8U443D7ZL}"
SCHEME="ClipNest"
BUNDLE_ID="com.tertiaryinfotech.clipnest"
DERIVED="${DERIVED:-/tmp/cn-phone}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

DEVICE="${1:-}"
if [ -z "$DEVICE" ]; then
  # xcodebuild wants the hardware UDID (00008130-000E782A26B8001C), not the
  # CoreDevice UUID that `devicectl list devices` prints — take it from xctrace.
  # Paired Macs show up there too, but their UUIDs have a different shape.
  DEVICE="$(xcrun xctrace list devices 2>/dev/null \
    | sed -n '/^== Devices ==/,/^== Simulators ==/p' \
    | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1)"
  if [ -z "$DEVICE" ]; then
    echo "No paired device found — connect and trust an iPhone/iPad first." >&2
    exit 1
  fi
fi

echo "==> building for $DEVICE (team $TEAM)"
xcodebuild -project "$ROOT/ClipNest.xcodeproj" -scheme "$SCHEME" \
  -destination "id=$DEVICE" -configuration Debug -derivedDataPath "$DERIVED" \
  -skipPackagePluginValidation -skipMacroValidation \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="Apple Development" PROVISIONING_PROFILE_SPECIFIER= \
  build

APP="$DERIVED/Build/Products/Debug-iphoneos/$SCHEME.app"
echo "==> installing $APP"
xcrun devicectl device install app --device "$DEVICE" "$APP"

echo "==> launching"
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID"

# On-device AI verification (§36⑫)
# ---------------------------------
# `ClipNestTests` is a macOS-only target, so its live-inference tests cannot run on an
# iPhone. `ClipNestDeviceTests` carries the device-safe subset:
#
#   xcodebuild test -project ClipNest.xcodeproj -scheme ClipNestDevice \
#     -destination "id=<UDID>" -configuration Debug \
#     -skipPackagePluginValidation -skipMacroValidation \
#     -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
#     DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic \
#     CODE_SIGN_IDENTITY="Apple Development" PROVISIONING_PROFILE_SPECIFIER=
#
# Those tests need the weights inside the app's data container. There is no CDN configured
# in this repo, so push them over USB instead:
#
#   REL="Library/Application Support/ClipNest/Models/qwen3-0.6b-4bit"
#   for f in /tmp/qwen-dl/*; do
#     xcrun devicectl device copy to --device "$DEVICE" \
#       --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
#       --source "$f" --destination "$REL/$(basename "$f")"
#   done
#
# Get the file list from Scripts/fetch-local-model.sh first, and copy
# model-manifest.json last: `isInstalled()` treats that file as the authoritative
# "this is complete" record, so it must not land before the weights do.
