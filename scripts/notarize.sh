#!/usr/bin/env bash
# Signiert (Developer ID), notarisiert und stapelt das fertige .app-Bundle.
#
# Zugang kommt aus scripts/release.env (gitignored; Vorlage: release.env.example):
#   DEV_ID_APP                              Code-Signing-Identität (Name oder SHA-1-Hash)
#   NOTARY_KEY/NOTARY_KEY_ID/NOTARY_ISSUER  App-Store-Connect-API-Key (bevorzugt)
#   oder NOTARY_PROFILE                     Keychain-Profil (Fallback)
# Werte lassen sich auch per Umgebungsvariable überschreiben.
#
# Nutzung:
#   scripts/notarize.sh "/Pfad/zu/Focuseditor.app"

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$ROOT/scripts/release.env" ]] && source "$ROOT/scripts/release.env"
source "$ROOT/scripts/lib-notary.sh"

APP_PATH="${1:?Pfad zum .app-Bundle angeben}"
DEV_ID_APP="${DEV_ID_APP:?DEV_ID_APP setzen (scripts/release.env oder Env)}"

echo "==> Signiere mit Hardened Runtime: $APP_PATH"
codesign --force --deep --options runtime \
  --sign "$DEV_ID_APP" \
  --timestamp \
  "$APP_PATH"

echo "==> Pruefe Signatur"
codesign --verify --strict --verbose=2 "$APP_PATH"

notarize_and_staple "$APP_PATH"

echo "==> Fertig. Gatekeeper-Check:"
spctl --assess --type execute --verbose=2 "$APP_PATH" || true
