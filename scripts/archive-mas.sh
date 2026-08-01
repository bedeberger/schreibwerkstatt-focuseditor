#!/usr/bin/env bash
# archive-mas.sh — App-Store-Paket (.pkg) des Targets „Focuseditor-MAS" bauen.
#
# Pendant zu scripts/release-dmg.sh, aber für den Mac App Store. Der Unterschied
# zum DMG-Weg (siehe SIGNING.md „App Store"):
#   - kein Sparkle im Bundle, keine mach-lookup-Sandbox-Exception
#   - KEINE Notarisierung (macht Apple beim Store-Ingest selbst)
#   - kein GitHub-Release, kein Git-Tag
#
# Ablauf:
#   1. DMG-Schema gegenbauen (Regressionsschutz für #if SPARKLE)
#   2. Archiv des MAS-Targets
#   3. Sanity-Check am archivierten Bundle: kein Sparkle, keine Exception-Entitlement
#   4. Export als .pkg (Config/ExportOptions-MAS.plist)
#   5. optional Upload zu App Store Connect (UPLOAD=1)
#
# Voraussetzungen (Apple-Kontoarbeit, siehe SIGNING.md „App Store"):
#   - App ID im Developer-Portal registriert
#   - Zertifikate „Apple Distribution" + „Mac Installer Distribution" im Keychain
#   - Provisioning-Profil „Mac App Store"
#   - App-Record in App Store Connect
# Fehlt davon etwas, bricht Schritt 4 mit einem Signier-/Profilfehler ab — der
# Archiv-Schritt davor läuft trotzdem durch und ist damit der nutzbare Teil,
# solange das Konto-Setup noch offen ist.
#
# Nutzung:
#   scripts/archive-mas.sh                # Archiv + Export nach build/mas/export
#   UPLOAD=1 scripts/archive-mas.sh       # zusätzlich hochladen (App-Manager-Key nötig)
#
# Umgebungsvariablen:
#   UPLOAD          1 = nach dem Export via notarytool-API-Key hochladen
#   VERSION         optional, sonst aus Version.xcconfig (SSoT)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$ROOT/scripts/release.env" ]] && source "$ROOT/scripts/release.env"

SCHEME="Focuseditor-MAS"
DMG_SCHEME="schreibwerkstatt-focuseditor"
CONFIG="Release"
DERIVED="$ROOT/build/mas"
VERSION="${VERSION:-$(awk -F'=' '/^MARKETING_VERSION/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$ROOT/Version.xcconfig")}"
ARCHIVE="$DERIVED/Focuseditor-$VERSION.xcarchive"
EXPORT_DIR="$DERIVED/export"

# --- 1. DMG-Schema gegenbauen ------------------------------------------------
# Beide Targets teilen den Quellcode; ein fehlender `#if SPARKLE`-Guard bricht
# genau eines von beiden. Hier früh auffallen lassen statt beim nächsten Release.
echo "==> Gegenprobe: DMG-Schema baut noch ($DMG_SCHEME)..."
( cd "$ROOT" && xcodebuild -scheme "$DMG_SCHEME" -configuration Debug build -quiet )

# --- 2. Archiv des MAS-Targets ----------------------------------------------
echo "==> Archiv ($SCHEME, Version $VERSION)..."
rm -rf "$ARCHIVE"
( cd "$ROOT" && xcodebuild -scheme "$SCHEME" -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED" -archivePath "$ARCHIVE" archive )

# --- 3. Sanity-Check: der App-Store-Blocker darf nicht zurückkommen ----------
APP="$ARCHIVE/Products/Applications/Focuseditor.app"
[[ -d "$APP" ]] || { echo "FEHLER: App im Archiv nicht gefunden: $APP" >&2; exit 1; }

echo "==> Sanity-Check (kein Sparkle, keine Sandbox-Exception)..."
fail=0
if codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q "temporary-exception"; then
  echo "  !! Entitlement mit temporary-exception gefunden — Store lehnt das ab" >&2; fail=1
fi
if [[ -d "$APP/Contents/Frameworks" ]] && ls "$APP/Contents/Frameworks" | grep -qi sparkle; then
  echo "  !! Sparkle.framework im Bundle" >&2; fail=1
fi
if [[ -d "$APP/Contents/XPCServices" ]]; then
  echo "  !! Contents/XPCServices vorhanden (Sparkle-Installer)" >&2; fail=1
fi
if plutil -p "$APP/Contents/Info.plist" | grep -q '"SU'; then
  echo "  !! SU*-Keys in der Info.plist" >&2; fail=1
fi
[[ $fail -eq 0 ]] || { echo "Abbruch: Store-Build ist nicht sauber." >&2; exit 1; }
echo "  ok — Bundle ist App-Store-tauglich"

# --- 4. Export als .pkg ------------------------------------------------------
echo "==> Export (.pkg)..."
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$ROOT/Config/ExportOptions-MAS.plist" \
  -exportPath "$EXPORT_DIR"

PKG="$(find "$EXPORT_DIR" -maxdepth 1 -name '*.pkg' | head -1)"
[[ -n "$PKG" ]] || { echo "FEHLER: kein .pkg im Export gefunden" >&2; exit 1; }
echo "==> Fertig: $PKG"

# --- 5. Optionaler Upload ----------------------------------------------------
# Achtung: der Notarisierungs-Key hat oft nur die Rolle „Developer" — für den
# Build-Upload braucht es „App Manager". Schlägt das fehl, ist der Key das
# Problem, nicht das Paket: dann über Transporter/Organizer hochladen.
if [[ "${UPLOAD:-}" == "1" ]]; then
  : "${NOTARY_KEY:?NOTARY_KEY fehlt (scripts/release.env)}"
  echo "==> Upload zu App Store Connect..."
  xcrun altool --upload-package "$PKG" --type macos \
    --apiKey "${NOTARY_KEY_ID:?}" --apiIssuer "${NOTARY_ISSUER:?}" \
    --bundle-id "David-Berger.schreibwerkstatt-focuseditor" \
    --bundle-version "$(awk -F'=' '/^CURRENT_PROJECT_VERSION/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$ROOT/Version.xcconfig")" \
    --bundle-short-version-string "$VERSION"
  echo "==> Hochgeladen. Verarbeitung in App Store Connect abwarten (~10–30 min)."
else
  cat <<EOF

Nächste Schritte (manuell):
  1. $PKG in Transporter laden und hochladen
     (oder Xcode -> Window -> Organizer -> Distribute App).
  2. App Store Connect: Build der Version zuordnen, „Was ist neu"-Text,
     Screenshots + Metadaten prüfen, zur Review einreichen.
  3. Bei Reject: CURRENT_PROJECT_VERSION in Version.xcconfig erhöhen — Apple
     nimmt keine Build-Nummer zweimal an.
EOF
fi
