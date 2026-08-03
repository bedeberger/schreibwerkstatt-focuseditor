# Sonden (Live-Messung am laufenden Client)

Ablage für **wegwerfbare** AppleScript-/Shell-Sonden, mit denen der laufende Mac-Client
gemessen statt vermutet wird (Maus-Geometrie, Caret, Cursor-Versatz, CPU-Spitzen).
Der Ordner ist per [.gitignore](.gitignore) inhaltlich ignoriert — nur diese README und
die `.gitignore` selbst sind getrackt. Sonden gehören **nicht** ins Repo: sie sind an
eine Fenstergeometrie, ein Buch und einen Messfall gebunden.

## Aufruf

```bash
PROBE_DIR=/pfad/zum/scratchpad osascript scripts/probes/probe7.scpt
```

Ohne `PROBE_DIR` schreiben die Sonden nach `~/Desktop`. Screenshot-Rechtecke
(`screencapture -R x,y,w,h`) und Klick-Koordinaten sind **fensterabhängig** und müssen
vor jedem Lauf neu bestimmt werden (Screenshot machen, Bildpixel ÷ 2 + Fensterursprung).

## Regeln, die sich bewährt haben

- App über `open -n <App.app>` starten, nie das Binary direkt — sonst wird sie nie frontmost.
- Immer der **Frontmost-Guard** im selben AppleScript (`… is not "Focuseditor" then return "ABORT"`),
  sonst landet der Tasten-Burst in der IDE.
- Synthetische Tasten erreichen die **WKWebView nicht** — nur AppKit-Shortcuts (⌘O, ⌘,, ⎋,
  Pfeile im nativen Picker) kommen an. Interaktionen im Text müssen von Hand gemacht werden.
- Die sandboxed Debug-App liest `/tmp` **nicht**: JS-Dateien für die WebView-Sonde müssen unter
  `~/Library/Containers/David-Berger.schreibwerkstatt-focuseditor/Data/tmp/` liegen.
- Laufende Instanz vorher beenden (zwei Instanzen teilen SQLite + Prefs), danach wieder starten.

## Bestand

- `probe6.scpt` — Seiten-Picker öffnen, Suchbegriff tippen, Ausschnitt aufnehmen (Basisbild).
- `probe7.scpt` — dito + Maus-Trajektorie in 12-px-Schritten mit Einzelbildern pro Position.
  Braucht ein `mousemove <x> <y>`-Hilfsprogramm in `PROBE_DIR` (CGEvent-Warp, ~10 Zeilen Swift).
