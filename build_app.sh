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
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=release
RUN=0
for arg in "$@"; do
  case "$arg" in
    debug) CONFIG=debug ;;
    release) CONFIG=release ;;
    --run) RUN=1 ;;
    *) echo "Unbekanntes Argument: $arg" >&2; exit 2 ;;
  esac
done

APP_NAME="DeskViewBookScanner"
BUNDLE_ID="org.crushkilldestroy.DeskViewBookScanner"
VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo 0.1)"
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

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>de</string>
  <key>CFBundleLocalizations</key><array><string>de</string><string>en</string></array>
  <key>CFBundleDisplayName</key><string>Desk View Book Scanner</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSScreenCaptureUsageDescription</key>
  <string>Der Buchscanner fotografiert das Fenster von Desk View, um daraus Seiten zu machen.</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$OUT/Contents/PkgInfo"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')"
  SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi
codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" --options runtime "$OUT"
echo "Gebaut: $OUT ($CONFIG, $VERSION, signiert mit: $SIGN_IDENTITY)"

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
