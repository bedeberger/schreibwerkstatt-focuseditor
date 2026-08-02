#!/usr/bin/env bash
#
# appstore-screenshots.sh — nimmt die App-Store-Screenshots (2880×1800) auf.
#
# Nimmt EINEN Sprachsatz auf (de oder en), je vier Aufnahmen:
#   01 Schreibfläche hell (Papier)   03 Einstellungen → Typografie
#   02 Seiten-Picker (⌘O)            04 Schreibfläche dunkel (Nacht)
#
# Aufruf:  scripts/appstore-screenshots.sh de
#          scripts/appstore-screenshots.sh en
#
# ── Warum eine eigene Kopie gebaut wird ───────────────────────────────────────
# Der Keychain-Eintrag des Clients hängt an einer festen (service, account)-
# Kombination, NICHT am Server und NICHT an der Bundle-ID. Ein Demo-Login aus
# der normalen App überschriebe damit das Produktions-Gerätetoken (das nur EINMAL
# angezeigt wird — es wäre weg). Der Screenshot-Build bekommt darum eine eigene
# Bundle-ID (eigener Container) UND einen eigenen Keychain-Service; die Quelle
# wird dafür kurz gepatcht und sofort wieder zurückgesetzt.
#
# ── Was das Skript NICHT kann ─────────────────────────────────────────────────
# Synthetische Tastendrücke erreichen die WKWebView nicht (nur AppKit-Shortcuts
# wie ⌘O/⌘, kommen an). Aufnahmen, die eine Interaktion IM Text brauchen
# (Synonym-Menü, Rechtschreib-Popover), müssen von Hand gemacht werden.
#
# Voraussetzungen: Bedienungshilfen-Recht für das aufrufende Terminal
# (System­einstellungen → Datenschutz & Sicherheit → Bedienungshilfen),
# Config/Demo.xcconfig vorhanden, Netz (Demo-Server + Editor-Bundle).

set -euo pipefail
cd "$(dirname "$0")/.."

LANG_ARG="${1:-de}"
case "$LANG_ARG" in de|en) ;; *) echo "Sprache muss de oder en sein"; exit 2 ;; esac

BUNDLE="David-Berger.schreibwerkstatt-focuseditor.shots"
APP="build/shots/Build/Products/Debug/Focuseditor.app"
PREFS="$HOME/Library/Containers/$BUNDLE/Data/Library/Preferences/$BUNDLE"
OUT="AppStore/screenshots/$LANG_ARG"
AUTH="schreibwerkstatt-focuseditor/Auth/AuthStore.swift"
# Fensterrahmen in Punkten; ×2 (Retina) = 2880×1800 Pixel.
X=60; Y=60; W=1440; H=900

mkdir -p "$OUT"

quit_app() {
  osascript -e "tell application id \"$BUNDLE\" to quit" 2>/dev/null || true
  sleep 3
  pkill -f "shots/Build.*Focuseditor" 2>/dev/null || true
  sleep 1
}

# Aktiviert die App und nimmt den Fensterbereich auf. Die IDE zieht den Fokus
# zwischen Aufrufen zurück — Aktivierung und Aufnahme gehören darum zusammen.
shoot() {
  osascript -e "tell application id \"$BUNDLE\" to activate" -e 'delay 1.2' >/dev/null
  screencapture -x -R $X,$Y,$W,$H "$1"
  swift scripts/strip-alpha.swift "$1" "$1.tmp" && mv "$1.tmp" "$1"
  echo "  → $1"
}

place_window() {
  osascript >/dev/null <<EOF
tell application id "$BUNDLE" to activate
delay 1
tell application "System Events"
  set p to first process whose bundle identifier is "$BUNDLE"
  set w to item 1 of (windows of p)
  set position of w to {$X, $Y}
  set size of w to {$W, $H}
end tell
delay 1.5
EOF
}

# ── 1. Isolierte Kopie bauen (eigene Bundle-ID + eigener Keychain-Service) ────
if [ ! -d "$APP" ]; then
  echo "▸ Screenshot-Kopie bauen …"
  cp "$AUTH" "$AUTH.orig"
  trap 'mv -f "$AUTH.orig" "$AUTH" 2>/dev/null || true' EXIT
  sed -i '' 's|ch.schreibwerkstatt.focuseditor.device-token|ch.schreibwerkstatt.focuseditor.device-token.shots|' "$AUTH"
  xcodebuild -scheme schreibwerkstatt-focuseditor -configuration Debug \
    -derivedDataPath build/shots PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE" build -quiet
  mv -f "$AUTH.orig" "$AUTH"
  trap - EXIT
  echo "  Quelle zurückgesetzt: $(git status --short "$AUTH" | wc -l | tr -d ' ') Änderungen offen (muss 0 sein)"
fi

# ── 2. Erst-Anmeldung am Demo-Konto (nur beim allerersten Lauf nötig) ─────────
if [ ! -d "$HOME/Library/Containers/$BUNDLE/Data" ]; then
  echo "▸ Erststart: bitte im Anmeldefenster einmal „Demo öffnen“ klicken."
  open -n "$APP"
  echo "  (danach das Skript erneut aufrufen)"
  exit 0
fi

# ── 3. Hell/Papier: Schreibfläche, Seiten-Picker, Einstellungen ───────────────
quit_app
defaults write "$PREFS" app.language     -string "$LANG_ARG"
defaults write "$PREFS" appearanceMode   -string light
defaults write "$PREFS" typo.paperTone   -string paper
defaults write "$PREFS" focusGranularity -string typewriter-only
open -n "$APP"
sleep 12
place_window

echo "▸ Aufnahmen $LANG_ARG (hell)"
shoot "$OUT/01-schreiben-hell.png"

osascript >/dev/null <<EOF
tell application id "$BUNDLE" to activate
delay 0.8
tell application "System Events"
  set p to first process whose bundle identifier is "$BUNDLE"
  if not (frontmost of p) then return "ABORT"
  keystroke "o" using command down
end tell
delay 1.5
EOF
shoot "$OUT/02-seiten-picker.png"

osascript >/dev/null <<EOF
tell application id "$BUNDLE" to activate
delay 0.8
tell application "System Events"
  set p to first process whose bundle identifier is "$BUNDLE"
  if not (frontmost of p) then return "ABORT"
  key code 53
  delay 0.8
  keystroke "," using command down
end tell
delay 2.5
tell application "System Events"
  set p to first process whose bundle identifier is "$BUNDLE"
  repeat with w in windows of p
    if (name of w) is not "Schreibwerkstatt Fokus" then set position of w to {470, 186}
  end repeat
end tell
delay 1
tell application "System Events"
  click at {708, 240}   -- Reiter „Typografie“
end tell
delay 1.5
EOF
shoot "$OUT/03-typografie.png"

# ── 4. Dunkel/Nacht: Schreibfläche ───────────────────────────────────────────
quit_app
defaults write "$PREFS" appearanceMode -string dark
defaults write "$PREFS" typo.paperTone -string night
open -n "$APP"
sleep 12
place_window
echo "▸ Aufnahme $LANG_ARG (dunkel)"
shoot "$OUT/04-schreiben-dunkel.png"

quit_app
echo "Fertig. Prüfen: alle 2880×1800, alpha=no"
for f in "$OUT"/*.png; do
  sips -g pixelWidth -g pixelHeight -g hasAlpha "$f" | tr '\n' ' '; echo
done
