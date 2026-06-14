# schreibwerkstatt-focuseditor (macOS-Client)

Nativer macOS-Client für den **Focus-Editor** der Schreibwerkstatt: eine SwiftUI/AppKit-Shell mit `WKWebView`, die ein **offline gebündeltes Build** des bestehenden Focus-Editors aus dem Hauptrepo lädt. Schreiben geht zuerst in einen lokalen SQLite-Spiegel; eine Sync-Engine schiebt Änderungen bei Konnektivität an den Server und zieht Deltas zurück.

**Zweck:** ablenkungsfreies Schreiben auf genau einer Seite, voll offline-fähig. Kein Buchorganizer, keine Analyse-Karten, keine KI-Jobs — nur der Schreibmodus.

## Quellprojekt (Single Source of Truth)

- Hauptrepo: `/Users/bd/ClaudeProjects/schreibwerkstatt`
- Der Editor-Code wird **nicht geforkt**. Ein Build-Step bündelt die unveränderten Quelldateien aus `public/js/editor/focus/` + `public/js/editor/shared/` (+ benötigtes `public/css/editor/`, `public/js/editor/shared/block-merge.js`) ins App-Paket (`Resources/web/`). SSoT bleibt das Hauptrepo — hier liegt **kein** kopierter Editor-Code, nur die Bridge und das Build-Skript.
- Bei Editor-Bugs/-Features: Fix gehört ins Hauptrepo, danach neu bündeln. Niemals den gebündelten Output von Hand patchen.

## Architektur

```
AppKit/SwiftUI-Shell
  └─ WKWebView  ──lädt──>  Resources/web/  (offline gebündeltes Focus-Editor-Build)
        │  WKScriptMessageHandler-Bridge (JS ⇄ Swift)
        ▼
  Swift-Kern
     ├─ LocalStore  (GRDB / SQLite-Spiegel der Seiten)
     ├─ Outbox      (Schreib-Queue, immer erst lokal)
     ├─ SyncEngine  (Reachability-getrieben: Push Outbox, Pull Deltas)
     └─ Auth        (Device-Token im Keychain)
                 │ HTTPS Bearer swd_…
                 ▼
        schreibwerkstatt-Server  (Express, Port 3737 / NGINX HTTPS)
```

**Offline-Kern-Prinzip:** Der WebView lädt **immer** das lokale Bundle, **nie** eine Server-URL. Die WebView kennt keinen Server — sie spricht ausschließlich über die Bridge mit dem Swift-Kern. Netzwerk macht nur der Swift-Kern.

## Bridge-Vertrag (JS ⇄ Swift)

Der Focus-Editor ruft heute Root-Methoden über `window.__app.*` und liest Root-Props. Im Bundle ersetzt eine **schlanke Bridge-Facade** diese Aufrufe — statt HTTP ruft sie über die WKWebView-Bridge den Swift-Kern.

Zu überbrückende Methoden:
- `startEdit` / `cancelEdit`
- `_flushDraftSaveNow` — Draft sofort persistieren
- `_markEditDirty` — Dirty-Flag setzen
- `_editCounterCtx` — Counter-/Kontext-Lieferant
- `_syncPageStatsAfterSave` — Stats nach Save aktualisieren

Zu liefernde Props (lesend für den Editor):
- `currentPage`, `renderedPageHtml`, `focusGranularity`, `editDirty`

Bridge-Nachrichten (Swift `WKScriptMessageHandler`), mindestens:
- `load { pageId }` → Swift liefert Seite aus LocalStore
- `save { pageId, html, baseUpdatedAt }` → Swift schreibt LocalStore + Outbox
- `list` → Buch-/Seitenliste aus LocalStore

**Regel:** Die Facade ist die **einzige** Kopplungsschicht. Kein direkter `fetch` aus dem gebündelten Editor-Code. Wenn der Editor eine neue Root-Methode braucht, wird sie zuerst in der Facade ergänzt und der Bridge-Vertrag hier dokumentiert.

## Server-Schnittstelle

Basis-URL konfigurierbar (Default Prod-Host). Auth über **Device-Token** (Bearer `swd_…`), nicht OIDC.

### Auth (Device-Token)
- Einmaliger Online-Login: Browser-OAuth-Flow am Server → User stellt im `/me`-Bereich ein Device-Token aus → Klartext (`swd_<64 hex>`) **genau einmal** sichtbar.
- Client cached das Token im **macOS Keychain** (nie in UserDefaults/Plist).
- Jeder Request: `Authorization: Bearer swd_…`. Der Server löst auf den echten User + dessen echte Rolle auf und respektiert das Status-Gate (suspended/deleted → 401).
- Token-Verwaltung am Server: `GET/POST /me/device-tokens`, `POST /me/device-tokens/:id/revoke`, `DELETE /me/device-tokens/:id`.
- 401 → Token ungültig/widerrufen: Client muss neu authentifizieren (Token aus Keychain löschen, Re-Login anstoßen). Ungespeicherte lokale Inhalte **nie** verwerfen.

### Sync
- **Pull:** `GET /sync/delta?since=<cursor>` → seit Cursor geänderte Seiten (`id`, `html`, `updated_at`). Cursor lokal persistieren, monoton vorrücken.
- **Push:** `PUT /content/pages/:id` mit `expected_updated_at`.
  - `200` → übernommen, Server-`updated_at` als neue Basis speichern.
  - `409` → Server liefert aktuellen Server-Stand zurück. Client löst per **3-Wege-Block-Merge** (`block-merge.js`, `data-bid`-basiert) in der WebView auf: kollisionsfrei → still mergen + erneut pushen; echte Block-Kollision → Konflikt-Modal des Editors.
- Inhalte fließen ausschließlich über die Content-Store-Semantik des Servers — kein Voll-Buch-`.swbook` für den Live-Sync (zu grob).

## Verzeichnislayout (Soll)

```
schreibwerkstatt-focuseditor/
  schreibwerkstatt-focuseditor/        App-Sources (Swift)
    *App.swift                         @main, Scene/Window
    ContentView.swift                  Shell-Root (WebView-Host)
    Web/                               WKWebView-Host + Bridge (WKScriptMessageHandler)
    Store/                             GRDB-LocalStore + Outbox
    Sync/                              SyncEngine + Reachability + Cursor
    Auth/                              Keychain + Device-Token + Login-Flow
    Resources/web/                     ← gebündeltes Editor-Build (Build-Step-Output, nicht versioniert/oder generiert)
  scripts/bundle-editor.*              Build-Step: zieht focus/ + shared/ aus dem Hauptrepo
```

## Harte Regeln

- **Kein Editor-Fork.** Editor-Logik, CSS und `block-merge.js` kommen aus dem Hauptrepo via Build-Step. Hier nur Bridge + Shell + Sync + Auth. Gebündelten Output nie von Hand editieren.
- **WebView lädt nur lokal.** Niemals eine Server-URL in den `WKWebView` laden. Server-Kontakt ausschließlich im Swift-Kern.
- **Local-first Writes.** Jeder Save geht zuerst in LocalStore + Outbox, erst danach (bei Konnektivität) zum Server. UI nie auf Netzwerk warten lassen.
- **Token nur im Keychain.** Device-Token niemals in UserDefaults, Plist, Logs oder Bridge-Messages an die WebView leaken. Die WebView braucht das Token nicht — Netzwerk macht Swift.
- **Konflikte über Block-Merge.** 409-Auflösung läuft über `block-merge.js` (3-Wege, `data-bid`), nicht über naives Last-Write-Wins. `data-bid`-Attribute nie strippen.
- **Datenverlust-Schutz vor allem.** Bei Auth-/Sync-Fehlern lokale Inhalte behalten; kein automatisches Verwerfen, kein Überschreiben ohne Merge.
- **Sprache:** UI-Texte folgen der Locale der Schreibwerkstatt (de/en). Code-Kommentare auf Deutsch (wie Hauptrepo).

## Build & Run

- Xcode-Projekt: `schreibwerkstatt-focuseditor.xcodeproj`. Target: macOS (SwiftUI-App-Lifecycle).
- Vor dem Build: Editor-Bundle erzeugen (Build-Step / Run-Script-Phase), das `focus/` + `shared/` aus dem Hauptrepo nach `Resources/web/` bündelt.
- Abhängigkeiten (geplant): GRDB (SQLite), Sparkle (Auto-Update, später).

## Roadmap (Plan)

1. **Bridge-Facade** im Hauptrepo (`editor/focus/` + `editor/shared/`) + Build-Step → Offline-Bundle.
2. **Device-Token-Auth** am Server — *erledigt* (Tabelle `device_tokens`, `swd_`-Bearer, `/me/device-tokens`). Frontend-UI zum Ausstellen noch offen.
3. **Inkrementeller Sync** am Server — `GET /sync/delta`, 409-Semantik auf `PUT /content/pages/:id`.
4. **macOS-Shell + Offline-Kern** — WKWebView + Bridge, GRDB-LocalStore, Outbox, SyncEngine (Reachability).
5. **Nativer Feinschliff** — Menüleiste, ⌘-Shortcuts, echtes Vollbild, Preferences, Dark Mode, Sparkle-Auto-Update, Code-Signing/Notarization.
