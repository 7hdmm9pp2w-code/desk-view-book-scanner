#!/bin/zsh
# Baut DeskViewBookScanner.app aus dem Swift Package und signiert es ad hoc.
#
# Grund für das Bundle: Die Bildschirmaufnahme-Freigabe hängt an einer Bundle-ID.
# Ein loses `swift build`-Binary erbt sie vom Terminal und verliert sie beim Neubau.
#
# Signatur: Ist eine "Apple Development"-Identität im Schlüsselbund, wird sie genommen,
# sonst ad hoc. Mit echter Identität bleibt die Freigabe über Neubauten erhalten; bei
# ad hoc ändert sich der Code-Hash mit jedem Build und macOS fragt unter Umständen neu.
# Überschreiben mit SIGN_IDENTITY="-" (ad hoc) oder SIGN_IDENTITY="<Name oder Hash>".
#
#   ./build_app.sh            → build/DeskViewBookScanner.app (release)
#   ./build_app.sh debug      → Debug-Konfiguration
#   ./build_app.sh --run      → bauen und starten
#   ./build_app.sh --without-pandoc → ohne mitgeliefertes Pandoc (kleineres Bundle)
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=release
RUN=0
WITH_PANDOC=1
for arg in "$@"; do
  case "$arg" in
    debug) CONFIG=debug ;;
    release) CONFIG=release ;;
    --run) RUN=1 ;;
    --without-pandoc) WITH_PANDOC=0 ;;
    *) echo "Unbekanntes Argument: $arg" >&2; exit 2 ;;
  esac
done

APP_NAME="DeskViewBookScanner"
BUNDLE_ID="org.crushkilldestroy.DeskViewBookScanner"
# Versionsnummer aus dem letzten Tag (v0.1.0 → 0.1.0), Build-Nummer aus der Zahl der
# Commits. Ohne Tag gilt 0.0.0; der genaue Stand steht zusätzlich in GitDescribe.
VERSION="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || echo v0.0.0)"
VERSION="${VERSION#v}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
GIT_DESCRIBE="$(git describe --tags --always --dirty 2>/dev/null || echo unbekannt)"
MIN_OS="26.0"

swift build -c "$CONFIG" --product "$APP_NAME"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

OUT="build/$APP_NAME.app"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$OUT/Contents/MacOS/$APP_NAME"

# Ressourcen-Bundle des Package-Targets (String-Kataloge). Bundle.module sucht es
# neben der ausführbaren Datei und unter Contents/Resources.
RESOURCE_BUNDLE="$BIN_DIR/${APP_NAME}_${APP_NAME}.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
  cp -R "$RESOURCE_BUNDLE" "$OUT/Contents/Resources/"
fi

# Pandoc als Hilfsprogramm (GPL, separater Prozess) samt Lizenztexten.
if [[ $WITH_PANDOC -eq 1 ]]; then
  ./scripts/fetch_pandoc.sh
  PANDOC_DIR="$(ls -d build/vendor/pandoc-*/ | head -1)"
  mkdir -p "$OUT/Contents/Helpers" "$OUT/Contents/Resources/Lizenzen"
  cp "$PANDOC_DIR/pandoc" "$OUT/Contents/Helpers/pandoc"
  cp "$PANDOC_DIR/COPYING.md" "$OUT/Contents/Resources/Lizenzen/Pandoc-COPYING.md"
  cp "$PANDOC_DIR/COPYRIGHT" "$OUT/Contents/Resources/Lizenzen/Pandoc-COPYRIGHT.txt"
fi
cp LICENSE "$OUT/Contents/Resources/Lizenzen/DeskViewBookScanner-EUPL-1.2.txt" 2>/dev/null || {
  mkdir -p "$OUT/Contents/Resources/Lizenzen"; cp LICENSE "$OUT/Contents/Resources/Lizenzen/DeskViewBookScanner-EUPL-1.2.txt"; }

# App-Icon aus dem Skript, einmal gerendert und dann wiederverwendet.
if [[ ! -f build/AppIcon.icns || scripts/make_icon.swift -nt build/AppIcon.icns ]]; then
  swift scripts/make_icon.swift build/AppIcon.icns
fi
cp build/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>de</string>
  <key>CFBundleLocalizations</key><array><string>de</string><string>en</string></array>
  <key>CFBundleDisplayName</key><string>Desk View Book Scanner</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>GitDescribe</key><string>$GIT_DESCRIBE</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCameraUsageDescription</key>
  <string>Der Buchscanner erfasst Buchseiten mit der gewählten Kamera, etwa Desk View oder einer 4K-Kamera über dem Buch.</string>
  <key>NSCameraUseContinuityCameraDeviceType</key><true/>
</dict>
</plist>
PLIST
printf 'APPL????' > "$OUT/Contents/PkgInfo"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')"
  SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi
# Hardened Runtime sperrt die Kamera, solange das Entitlement fehlt; ohne es gibt es
# weder den Freigabedialog noch einen Eintrag in den Systemeinstellungen.
cat > build/entitlements.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.camera</key><true/>
</dict>
</plist>
PLIST
if [[ -x "$OUT/Contents/Helpers/pandoc" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" --options runtime "$OUT/Contents/Helpers/pandoc"
fi
codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" --options runtime --entitlements build/entitlements.plist "$OUT"
echo "Gebaut: $OUT ($CONFIG, $VERSION ($BUILD_NUMBER), $GIT_DESCRIBE, signiert mit: $SIGN_IDENTITY)"

if [[ $RUN -eq 1 ]]; then
  # Alte Instanz beenden und warten, bis sie wirklich weg ist; sonst meldet `open`
  # Fehler -600, weil LaunchServices den sterbenden Prozess noch kennt.
  if pkill -x "$APP_NAME" 2>/dev/null; then
    for _ in {1..30}; do
      pgrep -x "$APP_NAME" >/dev/null || break
      sleep 0.1
    done
  fi
  open "$OUT"
fi
