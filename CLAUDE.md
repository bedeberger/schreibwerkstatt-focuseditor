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
     ├─ SyncEngine  (Scene-Phase-getriebenes Polling ~5 s + Reachability-Trigger; Push + Pull)
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

Bridge-Nachrichten **JS → Swift** (`WKScriptMessageHandlerWithReply`, je `{ op, params }`):
- `load { pageId }` → Seite aus LocalStore (`{ id, html, updatedAt, baseUpdatedAt? }`)
- `save { pageId, html, baseUpdatedAt? }` → LocalStore + Outbox (`{ id, updatedAt }`)
- `list { bookId? }` → Seitenliste aus LocalStore (optional buch-gefiltert)
- `log { level?, message }` → JS-Diagnose ins Swift-Log
- `editorState { pageId, dirty }` → meldet offene Seite + Dirty-Flag (steuert Open-Page-Reload/-Schutz im Sync)

Bridge-Kanal **Swift → JS** (`callAsyncJavaScript` in `contentWorld: .page`): Die Facade stellt einen Event-Bus `window.__focusBridge.on(event, cb)` / `_receive(event, payload)` bereit. Swift sendet:
- `serverUpdate { pageId, html, baseUpdatedAt }` → saubere offene Seite wurde serverseitig aktualisiert → still neu laden.
- `openPage { pageId, html, baseUpdatedAt }` → nativer Picker hat eine Seite gewählt → im Editor öffnen.

Block-Merge (409): `window.__focusBridge._merge3(base, local, server)` lädt das gebündelte `block-merge.js` dynamisch und liefert `{ merged, conflictCount }`. Der Swift-Kern ruft das beim 409-Push: `conflictCount == 0` → gemergtes HTML mit neuer Basis erneut pushen (still); `> 0` → Konflikt erfassen (Editor-Konflikt-UI). Merge-Ancestor (`base`) führt die SyncEngine als `serverBaseHtml` je Seite.

**Regel:** Die Facade ist die **einzige** Kopplungsschicht. Kein direkter `fetch` aus dem gebündelten Editor-Code. Wenn der Editor eine neue Root-Methode braucht, wird sie zuerst in der Facade ergänzt und der Bridge-Vertrag hier dokumentiert.

## Server-Schnittstelle

Basis-URL konfigurierbar (Default Prod-Host). Auth über **Device-Token** (Bearer `swd_…`), nicht OIDC.

### Auth (Device-Token)
- Einmaliger Online-Login: Browser-OAuth-Flow am Server → User stellt im `/me`-Bereich ein Device-Token aus → Klartext (`swd_<64 hex>`, serverseitig SHA256-gehasht) **genau einmal** sichtbar.
- **Kein Self-Minting:** Der Client kann ein Token **nicht selbst ausstellen** — `POST /me/device-tokens` lehnt mit `403 DEVICE_TOKEN_SELF_MINT_FORBIDDEN` ab, wenn der Request selbst per Device-Token läuft ([routes/usersettings.js](../../ClaudeProjects/schreibwerkstatt/routes/usersettings.js)). Der Login-Flow ist darum **Copy-Paste**: User stellt das Token in der Web-`/me`-Ansicht aus und fügt es im Client ein. Validierung im Client über `GET /me/device-tokens` (funktioniert mit Device-Token, nur das Ausstellen ist gesperrt).
- Client cached das Token im **macOS Keychain** (nie in UserDefaults/Plist).
- Jeder Request: `Authorization: Bearer swd_…`. Der Server löst auf den echten User + dessen echte Rolle auf und respektiert das Status-Gate (suspended/deleted → 401).
- Token-Verwaltung am Server: `GET/POST /me/device-tokens`, `POST /me/device-tokens/:id/revoke`, `DELETE /me/device-tokens/:id`.
- 401 → Token ungültig/widerrufen: Client muss neu authentifizieren (Token aus Keychain löschen, Re-Login anstoßen). Ungespeicherte lokale Inhalte **nie** verwerfen.

### Sync (Polling: Pull + Push)

Der Sync hält den lokalen Spiegel **aktuell, auch wenn eine Seite in einer anderen Session geändert wird** (Web-App, anderes Gerät). Mechanismus ist **Polling** des bestehenden Server-Endpoints — kein SSE/WebSocket-Push.

**Pull (Deltas ziehen) — `GET /content/books/:book_id/sync`** *(Server: erledigt, [routes/content.js](../../ClaudeProjects/schreibwerkstatt/routes/content.js) `GET /books/:book_id/sync`)*
- **Buch-skopiert** (braucht ein gewähltes `book_id`), nicht seiten-global. Ein `/sync/delta`-Endpoint existiert **nicht** — das war ein veralteter Plan.
- Query: `since=<ISO-8601>` + `since_id=<page_id>` + `limit=<n≤200>`. Ohne `since` = Voll-Pull (Baseline) des ganzen Buchs.
- **Keyset-Cursor `(updated_at, page_id)`:** Antwort liefert `cursor: { since, since_id }` (Position NACH der letzten gelieferten Seite) + `has_more`. Solange `has_more=true`, mit dem zurückgegebenen Cursor weiterpagen, bis erschöpft. Cursor **lokal persistieren** (since + since_id), monoton vorrücken.
- Antwort-Seiten tragen vollen HTML-Body: `{ page_id, page_name, chapter_id, updated_at, html }` + `now` (Server-Stempel).
- **Enthält eigene Edits** (anders als `/content/books/:id/changes`, das self-exkludiert + ohne HTML ist — das ist der Web-Collab-Toast-Pfad, nicht für uns). Der Client kann darum jeden Server-Stand übernehmen, auch von anderen eigenen Geräten/Sessions.

**Cross-Session-Frische (Polling-Loop):** Die SyncEngine pollt periodisch (Richtwert 5 s) `…/sync` mit dem gespeicherten Cursor — **nur solange App/Fenster aktiv** (Scene-Phase `.active` über `setActive(_:)`; im Hintergrund pausieren, beim Reaktivieren sofort einen Tick). Zusätzlicher Trigger: Reachability (Netz wieder erreichbar → sofort ein Tick). Eingehende Seiten in den LocalStore mergen, `baseUpdatedAt = Server-updated_at` setzen. Ist die **im Editor offene Seite** betroffen:
  - Editor **sauber** (nicht dirty) → Inhalt in der WebView still neu laden (Bridge-`load`), neuer `baseUpdatedAt` = Server-`updated_at`.
  - Editor **dirty** → lokalen Stand **nicht** überschreiben (Datenverlust-Schutz). Konflikt wird erst beim nächsten Push aufgelöst (409 → Block-Merge, s.u.).

**Push** — `PUT /content/pages/:id` mit `expected_updated_at` ([routes/content.js](../../ClaudeProjects/schreibwerkstatt/routes/content.js) `PUT /pages/:page_id`, Backend `savePage`). **Wichtig:** `expected_updated_at` ist der **exakte Server-ISO-String** (`WHERE updated_at = ?`, atomar) — nie aus Epoch-ms rekonstruieren, sonst bricht der Match. Der Client führt die ISO-Basis darum getrennt vom Epoch-ms-Store (`Sync/SyncState.swift`).
  - `200` → übernommen, Server-`updated_at` als neue Basis speichern, Outbox-Eintrag droppen.
  - `409 PAGE_CONFLICT` → Server liefert `server_updated_at` + `server_editor_email/name`. Client zieht den frischen Server-Stand (Pull der einen Seite) und löst per **3-Wege-Block-Merge** (`block-merge.js`, `data-bid`-basiert) in der WebView auf: kollisionsfrei → still mergen + erneut pushen; echte Block-Kollision → Konflikt-Modal des Editors.
  - `404 PAGE_NOT_FOUND` → **PUT updated nur, legt nicht an.** Neue Seiten entstehen über `POST /content/pages`, nicht über den Push. Ohne Server-Basis (Seite nie gepullt) wird darum **nicht** gepusht.
  - `423 PAGE_LOCKED` → Seite ist serverseitig gesperrt (Lektorats-Lock); später erneut versuchen, lokalen Stand behalten.

**Deletes:** `/sync` meldet nur geänderte/neue Seiten, **keine Löschungen**. Gelöschte Seiten reconciled der Client über `GET /content/books/:book_id/tree` (Soll-Bestand abgleichen).

**Ort des Codes:** `Sync/SyncEngine.swift` (Poll-Loop + Push + Pull), `Sync/SyncState.swift` (persistente Cursor + Server-ISO-Basis je Seite, eigener JSON-Snapshot), `Sync/Reachability.swift` (`NWPathMonitor`), `Sync/SyncModels.swift` (DTOs + ISO↔ms). Instanziiert app-weit in [AppCore.swift](schreibwerkstatt-focuseditor/AppCore.swift) (ein geteilter LocalStore für Bridge **und** Sync); Scene-Phase wird in [schreibwerkstatt_focuseditorApp.swift](schreibwerkstatt-focuseditor/schreibwerkstatt_focuseditorApp.swift) per `.onChange(of: scenePhase)` an `setActive(_:)` gereicht. Der Pull-Merge in den Store läuft über `applyServerPage(...)` (setzt `baseUpdatedAt` auf den Server-Stand, **kein** Outbox-Eintrag); der Push quittiert über `markPushed(...)`.

- Inhalte fließen ausschließlich über die Content-Store-Semantik des Servers — kein Voll-Buch-`.swbook` für den Live-Sync (zu grob).

## Verzeichnislayout (Soll)

```
schreibwerkstatt-focuseditor/
  schreibwerkstatt-focuseditor/        App-Sources (Swift)
    *App.swift                         @main, Scene/Window
    ContentView.swift                  Shell-Root (WebView-Host)
    Web/                               WKWebView-Host + Bridge (WKScriptMessageHandler)
    Store/                             GRDB-LocalStore + Outbox
    Sync/                              SyncEngine + Reachability + SyncState (Cursor/Basis) + SyncModels
    Auth/                              Keychain + Device-Token + Login-Flow
  web/                                 ← gebündeltes Editor-Build (Output von scripts/bundle-editor.mjs, gitignored)
                                         Top-Level (NICHT in App-Sources) + als Folder-Reference eingebunden →
                                         landet strukturerhaltend als Contents/Resources/web/ im App-Paket.
  scripts/bundle-editor.mjs            Build-Step: löst die ES-Modul-Import-Closure ab editor/focus.js auf und
                                         kopiert sie + Token/Editor-CSS + generiert index.html nach web/
```

**Warum `web/` top-level statt `Resources/web/`:** Der App-Sources-Ordner ist eine `PBXFileSystemSynchronizedRootGroup` (Xcode 16+) — sie schleust jede Datei darin **einzeln und flach** als Resource ein (verschachtelte Struktur kaputt → relative ES-Modul-Imports brechen). Eine Folder-Reference auf einen Ordner **ausserhalb** der Sync-Group kopiert den Baum dagegen verbatim. Daher liegt das Bundle top-level. Neue Swift-Dateien in den App-Sources kommen umgekehrt **automatisch** ins Target (kein pbxproj-Edit nötig).

## Harte Regeln

- **Kein Editor-Fork.** Editor-Logik, CSS und `block-merge.js` kommen aus dem Hauptrepo via Build-Step. Hier nur Bridge + Shell + Sync + Auth. Gebündelten Output nie von Hand editieren.
- **WebView lädt nur lokal.** Niemals eine Server-URL in den `WKWebView` laden. Server-Kontakt ausschließlich im Swift-Kern.
- **Local-first Writes.** Jeder Save geht zuerst in LocalStore + Outbox, erst danach (bei Konnektivität) zum Server. UI nie auf Netzwerk warten lassen.
- **Token nur im Keychain.** Device-Token niemals in UserDefaults, Plist, Logs oder Bridge-Messages an die WebView leaken. Die WebView braucht das Token nicht — Netzwerk macht Swift.
- **Konflikte über Block-Merge.** 409-Auflösung läuft über `block-merge.js` (3-Wege, `data-bid`), nicht über naives Last-Write-Wins. `data-bid`-Attribute nie strippen.
- **Datenverlust-Schutz vor allem.** Bei Auth-/Sync-Fehlern lokale Inhalte behalten; kein automatisches Verwerfen, kein Überschreiben ohne Merge.
- **Sprache:** UI-Texte folgen der Locale der Schreibwerkstatt (de/en). Code-Kommentare auf Deutsch (wie Hauptrepo).
- **Nach jeder Swift-Änderung builden.** Nach jeder Anpassung an Swift-Code den Build laufen lassen (s. „Build & Run") und Fehler/Warnings zurückmelden, bevor es weitergeht. Nicht ungeprüft mehrere Änderungen stapeln.

## Build & Run

- Xcode-Projekt: `schreibwerkstatt-focuseditor.xcodeproj`. Target: macOS (SwiftUI-App-Lifecycle).
- Vor dem Build: Editor-Bundle erzeugen (Build-Step / Run-Script-Phase), das `focus/` + `shared/` aus dem Hauptrepo nach `Resources/web/` bündelt.
- Abhängigkeiten (geplant): GRDB (SQLite), Sparkle (Auto-Update, später).
- **Build-Check nach jeder Swift-Änderung** (Pflicht, s. Harte Regeln):

  ```bash
  xcodebuild -scheme schreibwerkstatt-focuseditor -configuration Debug build
  ```

  Für kompakte Ausgabe `-quiet` anhängen. Verifiziert lauffähig am 2026-06-14 (`** BUILD SUCCEEDED **`).

## Roadmap (Plan)

1. **Bridge-Facade** im Hauptrepo (`editor/focus/` + `editor/shared/`) + Build-Step → Offline-Bundle.
2. **Device-Token-Auth** am Server — *erledigt* (Tabelle `device_tokens`, `swd_`-Bearer, `/me/device-tokens`). Frontend-UI zum Ausstellen noch offen.
3. **Inkrementeller Sync** am Server — *erledigt*: `GET /content/books/:book_id/sync` (Keyset-Cursor, voller HTML, inkl. eigener Edits) + 409-Semantik (`PAGE_CONFLICT`) auf `PUT /content/pages/:id`.
4. **macOS-Shell + Offline-Kern** — WKWebView + Bridge *(steht)*, LocalStore + Outbox *(steht, In-Memory/JSON-Platzhalter)*, GRDB *(offen)*, **SyncEngine (Polling-Pull + Push)** *(offen — Cross-Session-Frische, s. „Sync")*.
5. **Nativer Feinschliff** — Menüleiste, ⌘-Shortcuts, echtes Vollbild, Preferences, Dark Mode, Sparkle-Auto-Update, Code-Signing/Notarization.
