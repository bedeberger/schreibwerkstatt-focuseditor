#!/usr/bin/env bash
#
# appstore-review-video.sh — nimmt den Screencast für die App-Review auf
# (Guideline 2.1 „Information Needed": Apple verlangt ein Video, das mit dem
# App-Start beginnt und den typischen Ablauf inkl. Login und Kontolöschung zeigt).
#
# Aufruf:  scripts/appstore-review-video.sh
# Ergebnis: AppStore/review-video/focuseditor-review-<datum>.mov (+ komprimiert)
#
# ── Warum eine eigene Kopie ───────────────────────────────────────────────────
# Wie scripts/appstore-screenshots.sh: eigene Bundle-ID + eigener
# Keychain-Service, damit der Demo-Login NICHT das Produktions-Gerätetoken
# überschreibt (der Keychain-Eintrag hängt nicht an der Bundle-ID).
# Gebaut wird das **MAS-Target** — der DMG-Build zeigt im Konto-Reiter Sparkles
# „Check for Updates…", was im Store-Video nichts zu suchen hat.
#
# ── Was das Skript nicht kann ─────────────────────────────────────────────────
# * Synthetische Klicks über „System Events → click at" kommen in der SwiftUI-UI
#   nicht an; es klickt darum per CGEvent (Bedienungshilfen-Recht nötig).
# * Tasten erreichen die WKWebView NUR, wenn vorher in den Text geklickt wurde.
# * Der Scrollbereich der Einstellungen reagiert nicht auf synthetische
#   Scroll-Events → der Scrollbalken-Griff wird gezogen.
# * Koordinaten sind auf ein Fenster 1440×900 an (60,60) geeicht. Andere
#   Fenstergrösse/Position ⇒ Koordinaten neu ermitteln (screencapture + Bild
#   lesen, Bildpixel ÷ 2 + Fensterursprung).
#
# ── Achtung: die Aufnahme LÖSCHT das Demo-Konto ───────────────────────────────
# Der Ablauf endet mit „Delete account permanently". Beim Demo-Konto setzt der
# Server das Konto zurück statt es zu löschen (Tokens bleiben gültig) — die
# Demo-Inhalte sind danach auf dem Ausgangsstand.
#
# Voraussetzungen: Bedienungshilfen- UND Bildschirmaufnahme-Recht für das
# aufrufende Terminal, Config/Demo.xcconfig vorhanden, Netz (Demo-Server).

set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE="David-Berger.schreibwerkstatt-focuseditor.shots"
APP="build/shots-mas/Build/Products/Debug/Focuseditor.app"
PREFS="$HOME/Library/Containers/$BUNDLE/Data/Library/Preferences/$BUNDLE"
AUTH="schreibwerkstatt-focuseditor/Auth/AuthStore.swift"
KEYCHAIN_SERVICE="ch.schreibwerkstatt.focuseditor.device-token.shots"
OUT_DIR="AppStore/review-video"
STAMP="$(date +%Y-%m-%d)"
RAW="$OUT_DIR/focuseditor-review-$STAMP-raw.mov"
FINAL="$OUT_DIR/focuseditor-review-$STAMP.mov"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fenster: Position/Grösse in Punkten (×2 = Videoauflösung 2880×1800).
X=60; Y=60; W=1440; H=900
# Aufnahmedauer (Deckel; das Skript ist kürzer und wartet den Rest ab).
DURATION=155

mkdir -p "$OUT_DIR"

# ── Klick-/Zieh-Helfer (CGEvent) ──────────────────────────────────────────────
cat > "$TMP/click.swift" <<'SWIFT'
import CoreGraphics
import Foundation
let p = CGPoint(x: Double(CommandLine.arguments[1])!, y: Double(CommandLine.arguments[2])!)
func post(_ t: CGEventType) {
  CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?
    .post(tap: .cghidEventTap)
}
post(.mouseMoved);      usleep(180_000)
post(.leftMouseDown);   usleep(90_000)
post(.leftMouseUp)
SWIFT

cat > "$TMP/drag.swift" <<'SWIFT'
import CoreGraphics
import Foundation
let a = CGPoint(x: Double(CommandLine.arguments[1])!, y: Double(CommandLine.arguments[2])!)
let b = CGPoint(x: Double(CommandLine.arguments[3])!, y: Double(CommandLine.arguments[4])!)
func post(_ t: CGEventType, _ p: CGPoint) {
  CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?
    .post(tap: .cghidEventTap)
}
post(.mouseMoved, a);    usleep(250_000)
post(.leftMouseDown, a); usleep(200_000)
for i in 1...24 {
  let t = Double(i) / 24.0
  post(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
  usleep(35_000)
}
usleep(150_000)
post(.leftMouseUp, b)
SWIFT

# Vor jedem Klick aktivieren: CGEvent-Klicks gehen an das Fenster UNTER dem
# Zeiger — zieht eine andere App den Fokus, landet der Klick sonst dort.
activate_app() { osascript -e "tell application id \"$BUNDLE\" to activate" >/dev/null 2>&1 || true; }
click() { activate_app; sleep 0.6; swift "$TMP/click.swift" "$1" "$2" 2>/dev/null; }
drag()  { activate_app; sleep 0.6; swift "$TMP/drag.swift" "$1" "$2" "$3" "$4" 2>/dev/null; }

# Tasten nur mit Frontmost-Guard: parallel laufende IDEs ziehen den Fokus zurück.
keys() {
  osascript >/dev/null 2>&1 <<EOF
tell application id "$BUNDLE" to activate
delay 0.4
tell application "System Events"
  set p to first process whose bundle identifier is "$BUNDLE"
  if not (frontmost of p) then return "ABORT"
  $1
end tell
EOF
}

place_main_window() {
  osascript >/dev/null 2>&1 <<EOF
tell application id "$BUNDLE" to activate
delay 0.6
tell application "System Events"
  set p to first process whose bundle identifier is "$BUNDLE"
  set w to item 1 of (windows of p)
  set position of w to {$X, $Y}
  set size of w to {$W, $H}
end tell
EOF
}

place_settings_window() {
  osascript >/dev/null 2>&1 <<EOF
tell application "System Events"
  set p to first process whose bundle identifier is "$BUNDLE"
  repeat with w in windows of p
    if (name of w) is not "Schreibwerkstatt Fokus" then set position of w to {470, 186}
  end repeat
end tell
EOF
}

quit_app() {
  osascript -e "tell application id \"$BUNDLE\" to quit" 2>/dev/null || true
  sleep 3
  pkill -f "shots-mas/Build.*Focuseditor" 2>/dev/null || true
  sleep 1
}

# ── 1. Aufnahme-Kopie bauen (MAS-Target, eigene Bundle-ID + Keychain) ─────────
if [ ! -d "$APP" ]; then
  echo "▸ Aufnahme-Kopie bauen (Focuseditor-MAS) …"
  cp "$AUTH" "$AUTH.orig"
  trap 'mv -f "$AUTH.orig" "$AUTH" 2>/dev/null || true; rm -rf "$TMP"' EXIT
  sed -i '' "s|ch.schreibwerkstatt.focuseditor.device-token|$KEYCHAIN_SERVICE|" "$AUTH"
  xcodebuild -scheme Focuseditor-MAS -configuration Debug \
    -derivedDataPath build/shots-mas PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE" \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual PROVISIONING_PROFILE_SPECIFIER="" \
    build -quiet
  mv -f "$AUTH.orig" "$AUTH"
  trap 'rm -rf "$TMP"' EXIT
  echo "  Quelle zurückgesetzt: $(git status --short "$AUTH" | wc -l | tr -d ' ') Änderung(en) offen"
fi

# ── 2. Ausgangszustand: abgemeldet, englische UI, helles Papier ───────────────
echo "▸ Ausgangszustand herstellen …"
quit_app
security delete-generic-password -s "$KEYCHAIN_SERVICE" -a default >/dev/null 2>&1 || true
defaults write "$PREFS" app.language     -string en
defaults write "$PREFS" appearanceMode   -string light
defaults write "$PREFS" typo.paperTone   -string paper
defaults write "$PREFS" focusGranularity -string typewriter-only
# Fenster öffnet direkt im Aufnahmebereich (AppKit-Y = Bildschirmhöhe − Y − H).
FRAME_KEY="$(defaults read "$PREFS" 2>/dev/null | grep -o '"NSWindow Frame [^"]*"' | head -1 | tr -d '"' || true)"
[ -n "$FRAME_KEY" ] && defaults write "$PREFS" "$FRAME_KEY" -string "$X 169 $W $H 0 0 1800 1129"

# ── 3. Aufnahme starten ──────────────────────────────────────────────────────
echo "▸ Aufnahme läuft ($DURATION s Deckel) → $RAW"
rm -f "$RAW"
screencapture -v -k -V "$DURATION" -R $X,$Y,$W,$H "$RAW" &
REC_PID=$!
sleep 3

# ── 4. Ablauf ────────────────────────────────────────────────────────────────
echo "  · App starten (Login-Ansicht)"
open -n "$APP"
sleep 9
place_main_window
sleep 4                                   # Reviewer liest den Login-Screen

echo "  · „Open demo“"
click 949 720
sleep 22                                  # Editor-Bundle laden + Editor mounten

echo "  · Seiten-Picker (⌘O)"
# NICHT den Knopf der Leer-Ansicht klicken: hat die App die zuletzt offene Seite
# restauriert, gibt es ihn nicht und der Klick landet im Text (Pfeil/Return
# gehen dann in die Schreibfläche und fügen einen Absatz ein).
keys 'keystroke "o" using command down'
sleep 4
keys 'key code 125'                       # Pfeil runter
sleep 1.2
keys 'key code 125'
sleep 1.2
keys 'key code 36'                        # Return → Seite öffnen
sleep 5

echo "  · schreiben"
click 780 470                             # Caret in den Text setzen (Tasten erreichen die
                                          # WKWebView nur mit Fokus in der Schreibfläche)
sleep 1.2
keys 'key code 125 using command down'    # ⌘↓ ans Dokumentende — sonst landet der Satz
sleep 1                                   # mitten im bestehenden Absatz
keys 'keystroke " Es war der erste Morgen, "'
sleep 0.8
keys 'keystroke "an dem die Wohnung ihm fremd vorkam. "'
sleep 0.8
keys 'keystroke "Er zaehlte die Schritte im Flur."'
sleep 2.5
keys 'keystroke "s" using command down'   # ⌘S sichern
sleep 3

echo "  · Einstellungen"
keys 'keystroke "," using command down'
sleep 3
place_settings_window
sleep 1.5
click 592 242                             # General (die App merkt sich den letzten Reiter)
sleep 3
click 734 242                             # Typography
sleep 3
click 799 242                             # Writing
sleep 3
click 855 242                             # Sync
sleep 3

echo "  · Kontolöschung"
click 968 242                             # Account
sleep 3
drag 1078 300 1078 700                    # bis „Delete account“ scrollen
sleep 2
click 996 745                             # „Delete account…“
sleep 3
keys 'keystroke "DELETE"'
sleep 2
click 888 602                             # „Delete account permanently“
sleep 12                                  # Server löscht/setzt zurück, App meldet ab
keys 'keystroke return'                   # „Account deleted“-Dialog bestätigen (Standardknopf)
sleep 2
place_main_window
sleep 4

echo "  · erneut „Open demo“ (Demo-Konto wurde nur zurückgesetzt)"
click 949 720
sleep 22

echo "▸ Aufnahme abschliessen …"
kill -INT $REC_PID 2>/dev/null || true    # sauber beenden statt bis zum Deckel leerlaufen
wait $REC_PID 2>/dev/null || true
sleep 2
quit_app

# ── 5. Komprimieren (App Store Connect mag keine 100-MB-Anhänge) ─────────────
if [ -f "$RAW" ]; then
  echo "▸ Komprimieren → $FINAL"
  rm -f "$FINAL"
  # --duration schneidet den Leerlauf am Schluss weg (der Ablauf endet vor dem
  # Aufnahme-Deckel). KEIN --disableAudio: die Option existiert nicht und liess
  # avconvert still scheitern → 19-MB-Rohdatei als „komprimiertes" Ergebnis.
  avconvert --preset Preset1920x1080 --source "$RAW" --output "$FINAL" \
    --duration 142 --replace >/dev/null 2>&1 || cp "$RAW" "$FINAL"
  ls -lh "$RAW" "$FINAL" | awk '{print "  " $9 "  " $5}'
else
  echo "FEHLER: keine Aufnahme entstanden (Bildschirmaufnahme-Recht?)" >&2
  exit 1
fi
echo "Fertig."
