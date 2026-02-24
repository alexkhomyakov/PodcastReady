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
</dict>
</plist>
PLIST

# ── Step 7: Copy to /Applications ───────────────────────────────────────────
if [[ "$NO_COPY" == false ]]; then
    echo "7. Installing to /Applications/PodcastReady.app..."
    if [[ -d "/Applications/PodcastReady.app" ]]; then
        rm -rf "/Applications/PodcastReady.app"
    fi
    cp -R "$APP_BUNDLE" "/Applications/PodcastReady.app"
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
