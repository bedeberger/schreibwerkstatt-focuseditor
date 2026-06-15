#!/usr/bin/env bash
# Signiert (Developer ID), notarisiert und stapelt das fertige .app-Bundle.
#
# Voraussetzungen (siehe SIGNING.md):
#   - Apple Developer Program (kostenpflichtig) + "Developer ID Application"-Zertifikat im Login-Keychain
#   - notarytool-Keychain-Profil angelegt:
#       xcrun notarytool store-credentials swk-notary \
#         --apple-id "david.berger@dotag.ch" --team-id "<TEAM_ID>" --password "<app-specific-pw>"
#
# Nutzung:
#   scripts/notarize.sh "/Pfad/zu/Focuseditor.app"
#
# Erwartete Umgebungsvariablen (oder hier eintragen):
#   DEV_ID_APP   z.B. "Developer ID Application: David Berger (TEAMID)"
#   NOTARY_PROFILE  Default: swk-notary

set -euo pipefail

APP_PATH="${1:?Pfad zum .app-Bundle angeben}"
DEV_ID_APP="${DEV_ID_APP:?DEV_ID_APP setzen, z.B. 'Developer ID Application: David Berger (TEAMID)'}"
NOTARY_PROFILE="${NOTARY_PROFILE:-swk-notary}"

echo "==> Signiere mit Hardened Runtime: $APP_PATH"
codesign --force --deep --options runtime \
  --sign "$DEV_ID_APP" \
  --timestamp \
  "$APP_PATH"

echo "==> Pruefe Signatur"
codesign --verify --strict --verbose=2 "$APP_PATH"

ZIP_PATH="$(dirname "$APP_PATH")/$(basename "$APP_PATH" .app)-notarize.zip"
echo "==> Packe fuer Upload: $ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Sende an Apple-Notarisierung (wartet auf Ergebnis)"
xcrun notarytool submit "$ZIP_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo "==> Hefte Notarization-Ticket ans Bundle"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo "==> Fertig. Gatekeeper-Check:"
spctl --assess --type execute --verbose=2 "$APP_PATH" || true

rm -f "$ZIP_PATH"
