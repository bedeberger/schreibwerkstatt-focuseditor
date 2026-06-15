#!/usr/bin/env bash
# release-dmg.sh — Verteilbares, notarisiertes .dmg der Focus-Editor-App erzeugen.
#
# Ablauf (Gold-Standard für Verteilung außerhalb App Store):
#   1. App signieren + notarisieren + stapeln           -> scripts/notarize.sh
#   2. Drag-to-Applications-.dmg bauen (hdiutil, dependency-frei)
#   3. .dmg signieren (Developer ID Application + Timestamp)
#   4. .dmg notarisieren (notarytool --wait) + stapeln
#   5. Gatekeeper-Check (spctl)
#
# Voraussetzungen (siehe SIGNING.md):
#   - Apple Developer Program + "Developer ID Application"-Zertifikat im Keychain
#   - notarytool-Keychain-Profil (Default: swk-notary)
#
# Nutzung:
#   export DEV_ID_APP="Developer ID Application: David Berger (<TEAM_ID>)"
#   scripts/release-dmg.sh                       # baut Release frisch + erzeugt .dmg
#   scripts/release-dmg.sh /Pfad/zu/Focuseditor.app   # nutzt vorhandenes Build
#
# Umgebungsvariablen:
#   DEV_ID_APP      (Pflicht) Signier-Identität, z.B. "Developer ID Application: David Berger (TEAMID)"
#   NOTARY_PROFILE  Default: swk-notary
#   VERSION         optional, hängt sich an den .dmg-Dateinamen (z.B. 1.0.0)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$ROOT/scripts/release.env" ]] && source "$ROOT/scripts/release.env"
source "$ROOT/scripts/lib-notary.sh"

SCHEME="schreibwerkstatt-focuseditor"
CONFIG="Release"
DERIVED="$ROOT/build"
APP_NAME="Focuseditor.app"
DEV_ID_APP="${DEV_ID_APP:?DEV_ID_APP setzen (scripts/release.env oder Env)}"

# Version aus Version.xcconfig (SSoT) ableiten, falls nicht per Env vorgegeben.
VERSION="${VERSION:-$(awk -F'=' '/^MARKETING_VERSION/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$ROOT/Version.xcconfig")}"

# --- 0. App-Pfad bestimmen (Argument oder frischer Release-Build) -------------
APP_PATH="${1:-}"
if [[ -z "$APP_PATH" ]]; then
  echo "==> Release-Build ($SCHEME)..."
  ( cd "$ROOT" && xcodebuild -scheme "$SCHEME" -configuration "$CONFIG" \
      -derivedDataPath "$DERIVED" clean build )
  APP_PATH="$DERIVED/Build/Products/$CONFIG/$APP_NAME"
fi
[[ -d "$APP_PATH" ]] || { echo "FEHLER: App nicht gefunden: $APP_PATH" >&2; exit 1; }

# --- 1. App signieren + notarisieren + stapeln (vorhandenes Skript) ----------
echo "==> App signieren + notarisieren + stapeln..."
"$ROOT/scripts/notarize.sh" "$APP_PATH"

# --- 2. Drag-to-Applications-.dmg bauen --------------------------------------
OUT_DIR="$(dirname "$APP_PATH")"
DMG_BASE="Focuseditor${VERSION:+-$VERSION}"
DMG_PATH="$OUT_DIR/$DMG_BASE.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "==> .dmg-Inhalt vorbereiten (App + /Applications-Symlink)..."
cp -R "$APP_PATH" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> .dmg bauen: $DMG_PATH"
rm -f "$DMG_PATH"
hdiutil create \
  -volname "Focuseditor" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  "$DMG_PATH"

# --- 3. .dmg signieren --------------------------------------------------------
echo "==> .dmg signieren..."
codesign --force --sign "$DEV_ID_APP" --timestamp "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

# --- 4. .dmg notarisieren + stapeln ------------------------------------------
notarize_and_staple "$DMG_PATH"

# --- 5. Gatekeeper-Check ------------------------------------------------------
echo "==> Gatekeeper-Check (.dmg):"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH" || true

echo
echo "==> Fertig. Verteilbares Disk-Image:"
du -sh "$DMG_PATH"
echo "    $DMG_PATH"

# --- 6. Optional: als GitHub-Release veroeffentlichen ------------------------
# PUBLISH=1 -> das .dmg wird als "latest"-Release hochgeladen; der Server bietet
# es dann automatisch unter Profil-Einstellungen zum Download an.
if [[ "${PUBLISH:-0}" == "1" ]]; then
  echo
  echo "==> Veroeffentliche als GitHub-Release..."
  VERSION="${VERSION:-}" "$ROOT/scripts/publish-github-release.sh" "$DMG_PATH"
else
  echo
  echo "    Zum Veroeffentlichen: PUBLISH=1 scripts/release-dmg.sh   (oder"
  echo "    scripts/publish-github-release.sh \"$DMG_PATH\")"
fi
