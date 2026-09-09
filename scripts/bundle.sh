#!/usr/bin/env bash
#
# bundle.sh — Build PodcastReady and create a macOS .app bundle.
#
# Usage:
#   ./scripts/bundle.sh            # Build, bundle, and copy to /Applications
#   ./scripts/bundle.sh --no-copy  # Build and bundle only (skip /Applications copy)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build"
APP_BUNDLE="$BUILD_DIR/PodcastReady.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
BINARY_SRC="$PROJECT_ROOT/.build/release/PodcastReady"
ICON_SRC="$PROJECT_ROOT/PodcastReady/Resources/AppIcon.icns"

NO_COPY=false
if [[ "${1:-}" == "--no-copy" ]]; then
    NO_COPY=true
fi

echo "=== PodcastReady App Bundle Builder ==="
echo ""

# ── Step 1: Generate icon if missing ─────────────────────────────────────────
if [[ ! -f "$ICON_SRC" ]]; then
    echo "1. Generating app icon..."
    python3 "$SCRIPT_DIR/generate_icon.py"
else
    echo "1. App icon already exists, skipping generation."
fi

# ── Step 2: Build release binary ─────────────────────────────────────────────
echo "2. Building release binary with swift build..."
cd "$PROJECT_ROOT"
swift build -c release
echo "   Binary: $BINARY_SRC"

# ── Step 3: Create .app bundle structure ─────────────────────────────────────
echo "3. Creating .app bundle at $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# ── Step 4: Copy binary ─────────────────────────────────────────────────────
echo "4. Copying binary..."
cp "$BINARY_SRC" "$MACOS_DIR/PodcastReady"
chmod +x "$MACOS_DIR/PodcastReady"

# ── Step 5: Copy icon ───────────────────────────────────────────────────────
echo "5. Copying app icon..."
cp "$ICON_SRC" "$RESOURCES_DIR/AppIcon.icns"

# ── Step 6: Write Info.plist ─────────────────────────────────────────────────
echo "6. Writing Info.plist..."
cat > "$CONTENTS/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>PodcastReady</string>

    <key>CFBundleDisplayName</key>
    <string>PodcastReady</string>

    <key>CFBundleIdentifier</key>
    <string>com.curiositycode.podcastready</string>

    <key>CFBundleVersion</key>
    <string>1.0</string>

    <key>CFBundleShortVersionString</key>
    <string>1.0</string>

    <key>CFBundleExecutable</key>
    <string>PodcastReady</string>

    <key>CFBundleIconFile</key>
    <string>AppIcon</string>

    <key>CFBundlePackageType</key>
    <string>APPL</string>

    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>

    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>

    <key>LSUIElement</key>
    <true/>

    <key>NSCameraUsageDescription</key>
    <string>PodcastReady needs camera access to analyze your podcast video setup.</string>

    <key>NSHighResolutionCapable</key>
    <true/>

    <key>NSLocalNetworkUsageDescription</key>
    <string>PodcastReady controls your Elgato light over your local network.</string>

    <key>NSBonjourServices</key>
    <array>
        <string>_elg._tcp</string>
    </array>
</dict>
</plist>
PLIST

# ── Step 6b: Code sign ───────────────────────────────────────────────────────
#
# Signed with a STABLE identity rather than ad-hoc. An ad-hoc signature is
# derived from the binary's contents, so it changes on every build, and macOS
# treats each build as a different app — which meant re-granting Local Network
# permission (and losing sight of the Elgato light) after every single rebuild.
#
# Deliberately no --options runtime: the hardened runtime would additionally
# require com.apple.security.device.usb for the UVC camera control and
# device.camera for the preview, and there is nothing to gain here without
# notarisation. Plain signing is enough for a stable identity.
SIGN_ID="${PODCASTREADY_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')}"

# Sign a copy staged OUTSIDE the repo. The repo lives under Documents/, which
# is iCloud-synced, so the bundle carries com.apple.FinderInfo and a
# fileprovider attribute — and codesign refuses outright: "resource fork,
# Finder information, or similar detritus not allowed". `xattr -cr` does not
# stick there because the file provider puts them straight back.
#
# This mattered more than it sounds: with set -e the failure aborted the script
# BEFORE the install step, so the app silently stayed on the previous build
# while the console showed a build that had, in fact, succeeded.
STAGE="$(mktemp -d)/PodcastReady.app"
mkdir -p "$(dirname "$STAGE")"
ditto --norsrc --noextattr --noacl "$APP_BUNDLE" "$STAGE"
xattr -cr "$STAGE" 2>/dev/null || true

if [[ -n "$SIGN_ID" ]]; then
    echo "6b. Signing with: $SIGN_ID"
    codesign --force --deep --sign "$SIGN_ID" "$STAGE"
    codesign -dv "$STAGE" 2>&1 | grep -E "Authority|TeamIdentifier" | sed 's/^/    /'
else
    echo "6b. No Developer ID found — falling back to ad-hoc (permissions will reset each build)."
    codesign --force --deep --sign - "$STAGE"
fi

# The signed staged copy is what ships, and what the repo copy becomes.
rm -rf "$APP_BUNDLE"
ditto "$STAGE" "$APP_BUNDLE"

# ── Step 7: Copy to /Applications ───────────────────────────────────────────
if [[ "$NO_COPY" == false ]]; then
    echo "7. Installing to /Applications/PodcastReady.app..."
    if [[ -d "/Applications/PodcastReady.app" ]]; then
        rm -rf "/Applications/PodcastReady.app"
    fi
    ditto "$STAGE" "/Applications/PodcastReady.app"
    echo "   Installed."
else
    echo "7. Skipping /Applications copy (--no-copy flag)."
fi

echo ""
echo "=== Done ==="
echo "App bundle: $APP_BUNDLE"
if [[ "$NO_COPY" == false ]]; then
    echo "Installed:  /Applications/PodcastReady.app"
fi
echo ""
echo "To launch: open /Applications/PodcastReady.app"
