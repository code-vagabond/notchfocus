#!/usr/bin/env bash
# Build release binary and wrap it in a minimal .app so macOS TCC (Screen Recording,
# Accessibility, Automation) attributes permissions to NotchFocus, not Terminal.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release 2>&1 | grep -v warning | tail -3
BIN=".build/release/NotchFocus"
APP="NotchFocus.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NotchFocus"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>NotchFocus</string>
  <key>CFBundleDisplayName</key><string>NotchFocus</string>
  <key>CFBundleIdentifier</key><string>com.phungventures.notchfocus</string>
  <key>CFBundleVersion</key><string>0.1.0</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleExecutable</key><string>NotchFocus</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Reads the active browser tab URL so Jev can judge whether it matches your focus goal.</string>
</dict></plist>
PLIST

# Signing: set NOTCHFOCUS_SIGN_ID to a Developer ID / Apple Development identity so TCC grants
# (Screen Recording etc.) survive rebuilds. Default is ad-hoc, which re-prompts after every build.
#   security find-identity -v -p codesigning     # lists your identities
SIGN_ID="${NOTCHFOCUS_SIGN_ID:--}"
if [ "$SIGN_ID" = "-" ]; then
  codesign --force --sign - "$APP"
  echo "Signed ad-hoc (set NOTCHFOCUS_SIGN_ID for a stable TCC identity)"
else
  codesign --force --options runtime --entitlements scripts/entitlements.plist --sign "$SIGN_ID" "$APP"
  echo "Signed with: $SIGN_ID"
fi

# Optional: install a single canonical copy to /Applications (same signature ⇒ same TCC identity).
if [ "${NOTCHFOCUS_INSTALL:-0}" = "1" ]; then
  rm -rf "/Applications/$APP" && ditto "$APP" "/Applications/$APP"
  echo "Built $APP and installed to /Applications/$APP"
else
  echo "Built ./$APP  (NOTCHFOCUS_INSTALL=1 to copy to /Applications)"
fi
