#!/bin/zsh
# Lädt die festgenagelte Pandoc-Version für Apple Silicon samt Quell-Tarball nach
# build/vendor/ und prüft die SHA-256. Wird von build_app.sh aufgerufen.
#
# Lizenz: Pandoc ist GPL-2.0-or-later (© John MacFarlane). Die App ruft es als
# eigenen Prozess auf; das Bundle liefert den GPL-Text mit, und das Quell-Tarball
# liegt daneben, damit ein Release den Quellcode anbieten kann.
set -euo pipefail
cd "$(dirname "$0")/.."

PANDOC_VERSION="3.11"
BINARY_URL="https://github.com/jgm/pandoc/releases/download/${PANDOC_VERSION}/pandoc-${PANDOC_VERSION}-arm64-macOS.zip"
SOURCE_URL="https://github.com/jgm/pandoc/archive/refs/tags/${PANDOC_VERSION}.tar.gz"
# Nach dem ersten Download eingetragen; leer heißt: nur ausgeben, nicht prüfen.
BINARY_SHA256="15806bedf9517bfead72e88fe6a6696635c3691efbb6e152173440e9c5bb50b4"

VENDOR="build/vendor"
ZIP="$VENDOR/pandoc-${PANDOC_VERSION}-arm64-macOS.zip"
SRC="$VENDOR/pandoc-${PANDOC_VERSION}-src.tar.gz"
BIN="$VENDOR/pandoc-${PANDOC_VERSION}/pandoc"
COPYING="$VENDOR/pandoc-${PANDOC_VERSION}/COPYING"

mkdir -p "$VENDOR"

if [[ ! -f "$ZIP" ]]; then
  echo "Lade Pandoc ${PANDOC_VERSION} (arm64, ~40 MB) …"
  curl -fsSL -o "$ZIP" "$BINARY_URL"
fi
ACTUAL="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
if [[ -n "$BINARY_SHA256" && "$BINARY_SHA256" != "__BINARY_SHA256__" ]]; then
  if [[ "$ACTUAL" != "$BINARY_SHA256" ]]; then
    echo "SHA-256 von $ZIP stimmt nicht: $ACTUAL (erwartet $BINARY_SHA256)" >&2
    exit 1
  fi
else
  echo "Hinweis: BINARY_SHA256 im Skript eintragen: $ACTUAL"
fi

if [[ ! -x "$BIN" ]]; then
  rm -rf "$VENDOR/pandoc-${PANDOC_VERSION}" "$VENDOR/unzip"
  mkdir -p "$VENDOR/unzip"
  unzip -q "$ZIP" -d "$VENDOR/unzip"
  FOUND_BIN="$(find "$VENDOR/unzip" -type f -name pandoc -path '*/bin/*' | head -1)"
  FOUND_COPYING="$(find "$VENDOR/unzip" -type f \( -name COPYING -o -name COPYING.md -o -name COPYRIGHT \) | head -1)"
  [[ -n "$FOUND_BIN" ]] || { echo "Kein pandoc-Binary im Archiv" >&2; exit 1; }
  mkdir -p "$VENDOR/pandoc-${PANDOC_VERSION}"
  cp "$FOUND_BIN" "$BIN"
  chmod +x "$BIN"
  if [[ -n "$FOUND_COPYING" ]]; then cp "$FOUND_COPYING" "$COPYING"; fi
  find "$VENDOR/unzip" -type f \( -name "COPYING*" -o -name "COPYRIGHT*" \) -exec cp {} "$VENDOR/pandoc-${PANDOC_VERSION}/" \;
  rm -rf "$VENDOR/unzip"
fi

if [[ ! -f "$SRC" ]]; then
  echo "Lade Pandoc-Quellcode ${PANDOC_VERSION} …"
  curl -fsSL -o "$SRC" "$SOURCE_URL"
fi

# Lizenztexte aus dem Quell-Tarball; das Binär-Archiv enthält keine.
if [[ ! -f "$VENDOR/pandoc-${PANDOC_VERSION}/COPYING.md" ]]; then
  tar -xzf "$SRC" -C "$VENDOR/pandoc-${PANDOC_VERSION}" --strip-components=1 \
    "pandoc-${PANDOC_VERSION}/COPYING.md" "pandoc-${PANDOC_VERSION}/COPYRIGHT"
fi

"$BIN" --version | head -1
echo "Pandoc liegt unter $BIN, Quellcode unter $SRC"
