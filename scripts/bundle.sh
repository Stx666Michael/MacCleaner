#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "==> Building MacCleanerApp (Release)..."
swift build --disable-sandbox -c release

BIN_PATH="$(swift build --disable-sandbox -c release --show-bin-path)/MacCleanerApp"

if [ ! -f "docs/icon.png" ]; then
    echo "==> Generating icon and screenshots..."
    "$BIN_PATH" --generate-screenshots docs
fi

APP_NAME="MacCleaner"
APP_BUNDLE="dist/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_PATH" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

# Build AppIcon.icns from docs/icon.png if iconutil/sips are available
if [ -f "docs/icon.png" ] && command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
    ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET_DIR"
    sips -z 16 16     "docs/icon.png" --out "${ICONSET_DIR}/icon_16x16.png" >/dev/null 2>&1
    sips -z 32 32     "docs/icon.png" --out "${ICONSET_DIR}/icon_16x16@2x.png" >/dev/null 2>&1
    sips -z 32 32     "docs/icon.png" --out "${ICONSET_DIR}/icon_32x32.png" >/dev/null 2>&1
    sips -z 64 64     "docs/icon.png" --out "${ICONSET_DIR}/icon_32x32@2x.png" >/dev/null 2>&1
    sips -z 128 128   "docs/icon.png" --out "${ICONSET_DIR}/icon_128x128.png" >/dev/null 2>&1
    sips -z 256 256   "docs/icon.png" --out "${ICONSET_DIR}/icon_128x128@2x.png" >/dev/null 2>&1
    sips -z 256 256   "docs/icon.png" --out "${ICONSET_DIR}/icon_256x256.png" >/dev/null 2>&1
    sips -z 512 512   "docs/icon.png" --out "${ICONSET_DIR}/icon_256x256@2x.png" >/dev/null 2>&1
    sips -z 512 512   "docs/icon.png" --out "${ICONSET_DIR}/icon_512x512.png" >/dev/null 2>&1
    cp "docs/icon.png" "${ICONSET_DIR}/icon_512x512@2x.png"
    iconutil -c icns "$ICONSET_DIR" -o "${RESOURCES_DIR}/AppIcon.icns" || cp "docs/icon.png" "${RESOURCES_DIR}/AppIcon.png"
    rm -rf "$(dirname "$ICONSET_DIR")"
fi

cat > "${CONTENTS_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.maccleaner.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

if command -v codesign >/dev/null 2>&1; then
    SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -n 1)"
    if [ -n "$SIGN_ID" ]; then
        codesign --force --deep --sign "$SIGN_ID" "$APP_BUNDLE" >/dev/null 2>&1 || codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true
    else
        codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true
    fi
fi

echo "==> Packaged ${APP_BUNDLE}"
