#!/bin/zsh
# Baut "Dock Organizer.app" im Ordner build/
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Dock Organizer.app"
# Universell: läuft auf Apple Silicon und Intel-Macs
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/DockOrganizer" "$APP/Contents/MacOS/DockOrganizer"
# Übersetzungen (de = Entwicklungssprache, en); SwiftUI und String(localized:) suchen sie im App-Bundle
cp -R Resources/*.lproj "$APP/Contents/Resources/"

# Icon (Icon-Composer-Format mit Hell-/Dunkel-Variante; actool erzeugt Assets.car + AppIcon.icns als Fallback)
TMP=$(mktemp -d)
ICON="$TMP/AppIcon.icon"; mkdir -p "$ICON/Assets"
swift scripts/make-icon.swift "$ICON/Assets/foreground.png" light foreground
cp scripts/icon.json "$ICON/icon.json"
xcrun actool "$ICON" --compile "$PWD/$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 14.0 --app-icon AppIcon \
  --output-partial-info-plist "$TMP/partial.plist" >/dev/null
rm -rf "$TMP"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Dock Organizer</string>
  <key>CFBundleDisplayName</key><string>Dock Organizer</string>
  <key>CFBundleIdentifier</key><string>local.dockorganizer</string>
  <key>CFBundleExecutable</key><string>DockOrganizer</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleDevelopmentRegion</key><string>de</string>
  <key>CFBundleLocalizations</key><array><string>de</string><string>en</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array><dict>
    <key>CFBundleTypeName</key><string>Dock-Profil</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Owner</string>
    <key>CFBundleTypeIconFile</key><string>AppIcon</string>
    <key>LSItemContentTypes</key><array><string>local.dockorganizer.profile</string></array>
  </dict></array>
  <key>UTExportedTypeDeclarations</key>
  <array><dict>
    <key>UTTypeIdentifier</key><string>local.dockorganizer.profile</string>
    <key>UTTypeDescription</key><string>Dock-Profil</string>
    <key>UTTypeConformsTo</key><array><string>public.data</string></array>
    <key>UTTypeIconFile</key><string>AppIcon</string>
    <key>UTTypeTagSpecification</key><dict>
      <key>public.filename-extension</key><array><string>dockprofile</string></array>
    </dict>
  </dict></array>
</dict>
</plist>
PLIST

# Signieren: mit „Developer ID Application“-Zertifikat, falls vorhanden – sonst ad hoc (nur für diesen Mac)
SIGN_ID=$(security find-identity -v -p codesigning | sed -nE 's/.*"(Developer ID Application: [^"]+)".*/\1/p' | head -1)
if [[ -n "$SIGN_ID" ]]; then
  echo "Signiere mit: $SIGN_ID"
  codesign --force --options runtime --timestamp -s "$SIGN_ID" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
else
  echo "Kein „Developer ID Application“-Zertifikat gefunden – signiere ad hoc (nicht zum Weitergeben geeignet)."
  codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
fi

# Release-ZIP; mit NOTARIZE=1 vorher bei Apple notarisieren und das Ticket anheften
# Einmalig nötig: xcrun notarytool store-credentials "DockOrganizer" --apple-id <Apple-ID> --team-id <Team-ID>
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
ZIP="build/DockOrganizer-$VERSION.zip"
rm -f "$ZIP"
if [[ "${NOTARIZE:-0}" == "1" ]]; then
  [[ -n "$SIGN_ID" ]] || { echo "Notarisieren braucht ein „Developer ID Application“-Zertifikat." >&2; exit 1; }
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "${NOTARY_PROFILE:-DockOrganizer}" --wait
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose "$APP"
  rm -f "$ZIP"
fi
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Release-ZIP: $ZIP"

LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Nur die Kopie in /Applications soll bei macOS registriert sein (sonst taucht die App doppelt auf)
INSTALLED="/Applications/Dock Organizer.app"
osascript -e 'quit app id "local.dockorganizer"' >/dev/null 2>&1 || true
rm -rf "$INSTALLED"
cp -R "$APP" "$INSTALLED"
"$LSREG" -u "$PWD/$APP" >/dev/null 2>&1 || true
"$LSREG" -f "$INSTALLED" || true
echo "Fertig: $INSTALLED"
