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

echo
echo "=== 2. Verify the signature is notarisable ==="
# The hardened runtime is what notarisation requires; without it the submission
# is accepted and then rejected, which wastes a round trip.
if ! codesign -dv --verbose=2 "$APP" 2>&1 | grep -q "flags=.*runtime"; then
    echo "ERROR: the app is not signed with the hardened runtime." >&2
    echo "       bundle.sh falls back to ad-hoc when no Developer ID is found." >&2
    exit 1
fi
codesign --verify --strict --verbose=1 "$APP"

echo
echo "=== 3. Build the disk image ==="
rm -f "$DMG"
STAGE="$(mktemp -d)/PodcastReady"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/PodcastReady.app"
ln -s /Applications "$STAGE/Applications"          # drag-to-install
hdiutil create -volname "PodcastReady $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG" >/dev/null
echo "    $DMG"

echo
echo "=== 4. Notarise (this waits for Apple; usually 1-5 minutes) ==="
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

echo
echo "=== 5. Staple ==="
# Stapling writes the ticket into the dmg so it opens with no warning even
# offline. Without it the first launch needs a network round trip to Apple.
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo
echo "=== 6. Confirm Gatekeeper accepts it ==="
spctl --assess --type open --context context:primary-signature -vv "$DMG" 2>&1 | tail -3

echo
echo "Done. Attach to a release with:"
echo "  gh release create v$VERSION \"$DMG\" --title \"PodcastReady v$VERSION\" --notes-file <notes.md>"
