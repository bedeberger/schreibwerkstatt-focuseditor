#!/usr/bin/env bash
#
# build-and-install.sh — Release-Build der Focus-Editor-App erzeugen und nach
# /Applications kopieren (lokal signiert, "Sign to Run Locally").
#
# Verwendung:
#   ./scripts/build-and-install.sh
#
# Kein Apple-Developer-Account nötig — das Binary läuft auf diesem Mac.
# Für verteilbare (notarisierte) Builds braucht es einen separaten Export-Schritt.

set -euo pipefail

SCHEME="schreibwerkstatt-focuseditor"
CONFIG="Release"
# Projekt-Wurzel = ein Verzeichnis über diesem Skript
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="$ROOT/build"
APP_NAME="Focuseditor.app"
PRODUCT="$DERIVED/Build/Products/$CONFIG/$APP_NAME"
DEST="/Applications/$APP_NAME"

cd "$ROOT"

echo "==> Release-Build (${SCHEME})..."
xcodebuild \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  build

if [[ ! -d "$PRODUCT" ]]; then
  echo "FEHLER: Build-Produkt nicht gefunden unter $PRODUCT" >&2
  exit 1
fi

echo "==> Alte Version entfernen (falls vorhanden)..."
rm -rf "${DEST}"

echo "==> Kopiere nach ${DEST} ..."
cp -R "${PRODUCT}" "${DEST}"

echo "==> Fertig:"
du -sh "$DEST"
echo "    Starten mit: open \"$DEST\""
