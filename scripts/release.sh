#!/usr/bin/env bash
#
# release.sh — build, sign, notarise and package PodcastReady for distribution.
#
# Usage:
#   ./scripts/release.sh 2.0.0
#
# Requires notarisation credentials stored once:
#   xcrun notarytool store-credentials "PodcastReady" \
#       --apple-id <your-apple-id> --team-id <TEAM_ID> --password <app-specific-password>
#
# The app-specific password comes from appleid.apple.com > Sign-In and Security.
# It is NOT your Apple ID password, and it is stored in the login keychain, not
# in this repo.
set -euo pipefail

VERSION="${1:?usage: release.sh <version>, e.g. 2.0.0}"
PROFILE="${NOTARY_PROFILE:-PodcastReady}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build"
APP="$BUILD_DIR/PodcastReady.app"
DMG="$BUILD_DIR/PodcastReady.dmg"

echo "=== 1. Build and sign ==="
"$SCRIPT_DIR/bundle.sh" --no-copy

# Everything from here happens OUTSIDE the repo. build/ lives under Documents,
# which is iCloud-synced, and the file provider puts com.apple.FinderInfo back
# on the bundle as soon as bundle.sh copies the signed app there. codesign
# --verify --strict then rejects it — "resource fork, Finder information, or
# similar detritus not allowed" — even though the signature is perfectly valid.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ditto --norsrc --noextattr --noacl "$APP" "$WORK/PodcastReady.app"
xattr -cr "$WORK/PodcastReady.app" 2>/dev/null || true
APP="$WORK/PodcastReady.app"
DMG="$WORK/PodcastReady.dmg"

echo
echo "=== 2. Verify the signature is notarisable ==="
# The hardened runtime is what notarisation requires; without it the submission
# is accepted and then rejected, which wastes a round trip.
# Capture first, then match. `codesign ... | grep -q` looks natural and is a
# trap under `set -o pipefail`: grep -q exits on the first match, codesign gets
# SIGPIPE and returns non-zero, pipefail propagates that, and `!` inverts it —
# so the check fails exactly when the signature is correct.
SIG_INFO="$(codesign -dv --verbose=2 "$APP" 2>&1 || true)"
if ! grep -q "flags=.*runtime" <<<"$SIG_INFO"; then
    echo "ERROR: the app is not signed with the hardened runtime." >&2
    echo "       bundle.sh falls back to ad-hoc when no Developer ID is found." >&2
    exit 1
fi
codesign --verify --strict --verbose=1 "$APP"
SIGN_ID_USED="${PODCASTREADY_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')}"

echo
echo "=== 3. Notarise and staple the APP itself ==="
# The app gets its own ticket, not just the dmg. A ticket stapled only to the
# disk image leaves the app with nothing local, so a first launch with no
# network has to reach Apple to verify — which is exactly when a new user is
# most likely to see a scary dialog.
APP_ZIP="$BUILD_DIR/PodcastReady-app.zip"
rm -f "$APP_ZIP"
ditto -c -k --keepParent "$APP" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$APP_ZIP"

echo
echo "=== 4. Build the disk image ==="
rm -f "$DMG"
STAGE="$(mktemp -d)/PodcastReady"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/PodcastReady.app"
ln -s /Applications "$STAGE/Applications"          # drag-to-install
hdiutil create -volname "PodcastReady $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG" >/dev/null
echo "    $DMG"

echo
echo "=== 5. Sign the disk image ==="
# An unsigned dmg reports "no usable signature" to spctl even when the app
# inside is notarised. Signing it makes the container verifiable too.
codesign --force --timestamp --sign "$SIGN_ID_USED" "$DMG"

echo
echo "=== 6. Notarise and staple the disk image ==="
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo
echo "=== 7. Verify what a downloader actually gets ==="
# Assess the APP, not the container: --type open on a dmg answers a different
# question and reports "rejected" for an unsigned image even when the payload
# is fine.
MOUNT="$(hdiutil attach "$DMG" -nobrowse -readonly | grep -o '/Volumes/.*' | head -1)"
spctl --assess --type execute --verbose=4 "$MOUNT/PodcastReady.app" 2>&1 | tail -3
xcrun stapler validate "$MOUNT/PodcastReady.app" 2>&1 | tail -1
hdiutil detach "$MOUNT" -quiet

# Bring the finished image back into the repo for convenience. It is already
# signed, notarised and stapled, so an xattr landing on it now is harmless.
FINAL="$BUILD_DIR/PodcastReady.dmg"
ditto "$DMG" "$FINAL"

echo
echo "Done. Attach to a release with:"
echo "  gh release upload v$VERSION \"$FINAL\""
