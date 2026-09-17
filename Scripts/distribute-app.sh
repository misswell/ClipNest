#!/usr/bin/env bash
# Build the macOS ("desktop") ClipNest app and package it for distribution:
# Release build -> Developer ID signature -> notarization -> staple -> zip.
#
#   Scripts/distribute-app.sh
#
# Environment overrides (all optional):
#   CLIPNEST_DEVELOPER_ID        signing identity      (default: Developer ID Application: Guofeng Liu (U8U443D7ZL))
#   CLIPNEST_DEVELOPER_TEAM_ID   team id               (default: U8U443D7ZL)
#   CLIPNEST_NOTARY_APPLE_ID     Apple ID for notarytool
#   CLIPNEST_NOTARY_PASSWORD     app-specific password for notarytool
#   CLIPNEST_NOTARY_PROFILE      keychain profile for notarytool (used when the two above are unset)
#   CLIPNEST_ARCHS               architectures         (default: "arm64 x86_64")
#   CLIPNEST_DERIVED             derived data dir      (default: <repo>/dist/build)
#   CLIPNEST_OUTPUT_DIR          artifact dir          (default: <repo>/dist/release)
#
# Local smoke test without a Developer ID certificate:
#   CLIPNEST_SIGN_IDENTITY="-" CLIPNEST_SKIP_NOTARIZE=1 Scripts/distribute-app.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DEVELOPER_ID="${CLIPNEST_DEVELOPER_ID:-Developer ID Application: Guofeng Liu (U8U443D7ZL)}"
SIGN_IDENTITY="${CLIPNEST_SIGN_IDENTITY:-$DEVELOPER_ID}"
TEAM_ID="${CLIPNEST_DEVELOPER_TEAM_ID:-U8U443D7ZL}"
NOTARY_APPLE_ID="${CLIPNEST_NOTARY_APPLE_ID:-}"
NOTARY_PASSWORD="${CLIPNEST_NOTARY_PASSWORD:-}"
NOTARY_PROFILE="${CLIPNEST_NOTARY_PROFILE:-}"
SKIP_NOTARIZE="${CLIPNEST_SKIP_NOTARIZE:-0}"
ARCHS_WANTED="${CLIPNEST_ARCHS:-arm64 x86_64}"
DERIVED="${CLIPNEST_DERIVED:-$ROOT/dist/build}"
OUTPUT_DIR="${CLIPNEST_OUTPUT_DIR:-$ROOT/dist/release}"

# project.yml is the single source of truth: ClipNest.xcodeproj is gitignored and
# Info.plist is generated, so MARKETING_VERSION is what the release tag must match.
VERSION="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([0-9][^"]*)"?[[:space:]]*$/\1/p' project.yml | head -1)"
if [[ -z "$VERSION" ]]; then
    echo "Could not read MARKETING_VERSION from project.yml" >&2
    exit 1
fi

APP="$DERIVED/Build/Products/Release/ClipNest.app"
ZIP="$OUTPUT_DIR/ClipNest-$VERSION-macos.zip"
mkdir -p "$OUTPUT_DIR"

command -v xcodegen >/dev/null || { echo "xcodegen is not installed" >&2; exit 1; }

echo "==> Generating ClipNest.xcodeproj"
xcodegen generate

echo "==> Building ClipNest $VERSION ($ARCHS_WANTED), unsigned"
# Compile with signing switched off, then apply the signature below by hand.
#
# Letting xcodebuild resolve the identity looks simpler, but on the CI runner it fails
# before compiling anything, for every target including the SwiftPM package ones, with
# "No certificate for team ... matching ... found" — even though the certificate was
# present, unexpired, and visible through the keychain search list. The resolver is also
# being asked to pick a distribution certificate for package targets that have no reason
# to carry one. Signing here instead sidesteps both, and the seal becomes inspectable.
#
# project.yml still pins the upstream team (GU9WTSTX9M) and the App Store profile for the
# iphoneos SDK; neither applies to a Release macOS build that is not signed by Xcode.
# This disables signing for this one build only — simulator and device builds keep the
# automatic signing configured in project.yml.
xcodebuild -project ClipNest.xcodeproj -scheme ClipNest \
    -configuration Release -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" -skipPackagePluginValidation -skipMacroValidation \
    ARCHS="$ARCHS_WANTED" ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" CODE_SIGN_ENTITLEMENTS="" \
    DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER= \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    build

[[ -d "$APP" ]] || { echo "Missing built app at $APP" >&2; exit 1; }

echo "==> Signing with $SIGN_IDENTITY"
ENTITLEMENTS="$ROOT/Sources/MarkdownVault.entitlements"
[[ -f "$ENTITLEMENTS" ]] || { echo "Missing entitlements at $ENTITLEMENTS" >&2; exit 1; }

# Signing happens after a long compile, so report what is actually reachable now. A
# locked keychain surfaces from codesign as "The specified item could not be found in
# the keychain", which reads like a missing certificate; this makes the real cause plain.
echo "--- identities visible while signing ---"
security find-identity -v -p codesigning || true

# Inside out: embedded code must be sealed before the bundle that contains it, otherwise
# the outer signature is computed over unsigned nested binaries. Today the main executable
# is the only Mach-O in the bundle, so this loop is a no-op, but a future dependency can
# add an embedded framework or dylib and this keeps the seal correct when it does.
while IFS= read -r -d '' nested; do
    codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$nested"
done < <(find "$APP/Contents" -depth \
    \( -name "*.dylib" -o -name "*.so" -o -name "*.framework" -o -name "*.xpc" -o -name "*.app" \) \
    -print0 2>/dev/null)

# Hardened runtime plus the app's own entitlements. get-task-allow must not be present or
# the notary service rejects the upload, which is why base entitlements stay uninjected.
codesign --force --timestamp --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" "$APP"

codesign --verify --deep --strict "$APP"

echo "==> Zipping for notarization"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

if [[ "$SKIP_NOTARIZE" == "1" ]]; then
    echo "==> Skipping notarization (CLIPNEST_SKIP_NOTARIZE=1)"
else
    echo "==> Submitting to Apple notarization service"
    if [[ -n "$NOTARY_APPLE_ID" || -n "$NOTARY_PASSWORD" ]]; then
        if [[ -z "$NOTARY_APPLE_ID" || -z "$NOTARY_PASSWORD" ]]; then
            echo "Both CLIPNEST_NOTARY_APPLE_ID and CLIPNEST_NOTARY_PASSWORD are required for password-based notarization." >&2
            exit 1
        fi
        xcrun notarytool submit "$ZIP" \
            --apple-id "$NOTARY_APPLE_ID" \
            --team-id "$TEAM_ID" \
            --password "$NOTARY_PASSWORD" \
            --wait
    elif [[ -n "$NOTARY_PROFILE" ]]; then
        xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    else
        echo "No notarization credentials provided (CLIPNEST_NOTARY_APPLE_ID/PASSWORD or CLIPNEST_NOTARY_PROFILE)." >&2
        exit 1
    fi

    echo "==> Stapling notarization ticket"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"

    echo "==> Re-zipping the stapled app"
    rm -f "$ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
fi

echo "==> Verifying final artifact"
codesign --verify --deep --strict "$APP"
codesign --display --verbose=2 "$APP" 2>&1 | grep -E "^(Authority|TeamIdentifier|Identifier)=" || true
if [[ "$SKIP_NOTARIZE" != "1" ]]; then
    spctl --assess --type execute --verbose "$APP"
fi
echo "architectures: $(lipo -archs "$APP/Contents/MacOS/ClipNest")"
shasum -a 256 "$ZIP"

echo "Done."
echo "  App: $APP"
echo "  ZIP: $ZIP"
