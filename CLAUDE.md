# schreibwerkstatt-focuseditor (macOS-Client)

Nativer macOS-Client für den **Focus-Editor** der Schreibwerkstatt: eine SwiftUI/AppKit-Shell mit `WKWebView`, die ein **lokal gecachtes Build** des bestehenden Focus-Editors lädt. Das Build wird **zur Laufzeit per OTA vom Server gezogen** (statt zur Build-Zeit gebündelt) und im App-Support gecacht. Schreiben geht zuerst in einen lokalen SQLite-Spiegel; eine Sync-Engine schiebt Änderungen bei Konnektivität an den Server und zieht Deltas zurück.

**Zweck:** ablenkungsfreies Schreiben auf genau einer Seite, voll offline-fähig. Kein Buchorganizer, keine Analyse-Karten, keine KI-Jobs — nur der Schreibmodus.

## Über dieses Projekt

Die **Schreibwerkstatt** ist eine Web-Plattform zum strukturierten Schreiben von Büchern (Express-Server, Editor, Buch-/Kapitel-Organisation, Lektorat, Analyse-Karten, KI-Jobs). Dieser **Focus-Editor-Client** ist eine eigenständige, abgespeckte native macOS-App, die *nur* den Schreibmodus der Plattform herausschält: eine Seite, kein Drumherum, voll offline-fähig. Er ersetzt die Web-Plattform nicht, sondern ist ein fokussierter Schreib-Frontend für dieselben Inhalte — Seiten, die hier entstehen, leben über den Sync im selben Datenbestand wie die Web-App.

**Verhältnis zum Mutterprojekt:** Der Editor-Code (JS/CSS, Block-Merge) wird **nicht** kopiert, sondern zur Laufzeit als OTA-Bundle vom Server gezogen — die Schreibwerkstatt bleibt Single Source of Truth (Details unten unter „Quellprojekt"). Dieser Client liefert nur die native Hülle: Shell, Bridge, Offline-Store, Sync, Auth, OTA-Lader.

**Repositories:**
- **Mutterprojekt (Schreibwerkstatt, SSoT):** GitHub [`bedeberger/schreibwerkstatt`](https://github.com/bedeberger/schreibwerkstatt) (public) · lokal `/Users/bd/ClaudeProjects/schreibwerkstatt`
- **Dieser Client:** GitHub `bedeberger/schreibwerkstatt-focuseditor` (private) · lokal `/Users/bd/xcode-projects/schreibwerkstatt-focuseditor`

## Quellprojekt (Single Source of Truth)

- Hauptrepo: `/Users/bd/ClaudeProjects/schreibwerkstatt`
- Der Editor-Code wird **nicht geforkt** und **nicht zur Build-Zeit kopiert**. Der Server bündelt die unveränderte ES-Modul-Import-Closure (ab `public/js/editor/focus.js` / `focus/standalone.js` / `shared/editor-host.js` / `shared/block-merge.js`) + die Focus-Editor-CSS als **OTA-ZIP** und liefert sie über `GET /content/editor-bundle.zip` aus ([lib/editor-bundle.js](../../ClaudeProjects/schreibwerkstatt/lib/editor-bundle.js)). Der Client zieht das ZIP zur Laufzeit und cacht es lokal. SSoT bleibt das Hauptrepo — hier liegt **kein** kopierter Editor-Code, nur Bridge + Shell + Sync + Auth + OTA-Lader.
- Bei Editor-Bugs/-Features: Fix gehört ins Hauptrepo. Der nächste Start des Clients zieht das aktualisierte Bundle automatisch (ETag-getrieben). Niemals den gecachten Output von Hand patchen.
- **Das `index.html` (Boot/Bridge) ist NICHT im Server-Bundle** — es ist Client-Glue (adaptiert `window.__focusBridge` auf den standalone-Vertrag) und liegt in [Web/WebAssets.swift](schreibwerkstatt-focuseditor/Web/WebAssets.swift) (`indexHTML(cssFiles:sourceCommit:)`). Der Client schreibt es beim Entpacken aus dem Manifest in den Cache.

## Architektur

> **Detaillierte Implementierungs-Referenz: [ARCHITECTURE.md](ARCHITECTURE.md)** — konkrete Typen, Besitzverhältnisse (`AppCore`-Komposition), Datenflüsse und „wo was hingehört". Dieser Abschnitt gibt den Überblick; ARCHITECTURE.md geht in den Code.

```
AppKit/SwiftUI-Shell
  └─ WKWebView  ──lädt (swk-app://)──>  web-cache/  (lokal gecachtes Focus-Editor-Build)
        │  WKScriptMessageHandler-Bridge (JS ⇄ Swift)
        ▼
  Swift-Kern
     ├─ LocalStore         (GRDB / SQLite-Spiegel der Seiten)
     ├─ Outbox             (Schreib-Queue, immer erst lokal)
     ├─ SyncEngine         (Scene-Phase-getriebenes Polling ~5 s + Reachability-Trigger; Push + Pull)
     ├─ EditorBundleStore  (OTA: zieht/cacht das Editor-Bundle, ETag-getrieben)
     └─ Auth               (Device-Token im Keychain)
                 │ HTTPS Bearer swd_…
                 ▼
        schreibwerkstatt-Server  (Express, Port 3737 / NGINX HTTPS)
```

**Offline-Kern-Prinzip:** Der WebView lädt **immer** den lokalen Cache, **nie** eine Server-URL. Die WebView kennt keinen Server — sie spricht ausschließlich über die Bridge mit dem Swift-Kern. Netzwerk macht nur der Swift-Kern (Sync **und** OTA-Bundle-Refresh). Nach dem ersten erfolgreichen Bundle-Download arbeitet die App vollständig offline; nur der **allererste** Start braucht Netz (der Device-Token-Login ist ohnehin online).

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
- `editorState { pageId, dirty, bookId? }` → meldet offene Seite + Dirty-Flag (steuert Open-Page-Reload/-Schutz im Sync). Merkt nebenbei die zuletzt geöffnete Seite gerätelokal — **pro Buch** (UserDefaults `editor.lastOpenByBook.<server>`, Dict `bookId→pageId`, via `bookId`) **und** global (Legacy-Key `editor.lastOpenPageId.<server>`); nur echte Seiten.
- `lastOpenPage { bookId? }` → `{ pageId }` (zuletzt geöffnete Seite, gerätelokal; mit `bookId` **buch-skopiert**, ohne den globalen Legacy-Wert; `null` wenn für das Buch nie geöffnet). Boot-Pull: der Editor-Glue (`loadPage` in [WebAssets.swift](schreibwerkstatt-focuseditor/Web/WebAssets.swift)) bevorzugt sie **nur für das aktive Buch** und nur, falls noch in dessen Seitenliste — sonst erste Seite. **Ohne aktives Buch** (Erststart-Race) wird **nie** restauriert (verhinderte den „falsches Buch geöffnet"-Bug).
- `spellcheckConfig {}` → `{ enabled, debounceMs }` (aus `GET /config`, in der Bridge gecacht)
- `languagetoolCheck { text, language?, pageId?, bookId? }` → `{ matches: [...] }` | `{ disabled: true }` (Proxy `POST /languagetool/check`; `404` = serverseitig aus). **Lokale Overrides** (UserDefaults, `SpellcheckPrefs` in [EditorBridge.swift](schreibwerkstatt-focuseditor/Web/EditorBridge.swift)): `spellcheck.localEnabled=false` → `{ disabled: true }` ohne Roundtrip; `spellcheck.languageOverride` (≠ „auto") übersteuert die gesendete Sprache.
- `dictionaryAdd { word, lang?, bookId? }` → `{ ok }` (Proxy `POST /dictionary`, User-Wörterbuch)
- `focusGranularity {}` → `{ granularity }` (lokale Fokus-Stufe, Boot-Pull)
- `editorTypography {}` → CSS-fertiges Payload `{ fontSize, lineHeight, measure, fontFamily, paperBg?, paperText?, focusDim? }` (lokale Typografie inkl. Fokus-Abdunklung, Boot-Pull; vom `TypographyController`, [Theme/TypographyController.swift](schreibwerkstatt-focuseditor/Theme/TypographyController.swift))
- `editorBehavior {}` → `{ autosaveMs }` (lokales Editor-Verhalten, Boot-Pull; an `mountStandaloneFocus({ autosaveMs })` durchgereicht, `EditorBehaviorPrefs` in [EditorBridge.swift](schreibwerkstatt-focuseditor/Web/EditorBridge.swift))
- `reportStats { words, chars, pageId? }` → `null` (JS meldet Live-Wort-/Zeichenzahl der offenen Seite; treibt Toolbar-Stats, Schreibziel und den Tages-Delta im `WritingStatsStore`, [Writing/WritingStatsStore.swift](schreibwerkstatt-focuseditor/Writing/WritingStatsStore.swift))

**Rechtschreibprüfung (LanguageTool):** Der unveränderte Editor-Controller (`public/js/cards/editor-spellcheck/controller.js` im Hauptrepo) wird ins OTA-Bundle gezogen und im Boot ([WebAssets.swift](schreibwerkstatt-focuseditor/Web/WebAssets.swift) `indexHTML`) verdrahtet; statt direktem `fetch` laufen Prüfung + Wörterbuch über die obigen Bridge-Ops. Settings (enabled/url/picky/rules) liegen **serverseitig** in `app_settings` und werden vom Proxy angewandt — der Client liefert nur Text + `bookId`/`pageId`. **Locale:** Client sendet `language:"auto"` + `bookId`; serverseitig gewinnt `getBookLocale(bookId)` → `de-CH`. Online-only (kein Offline-Kern-Inhalt); offline/`404` degradiert still. Voraussetzung im Hauptrepo (SSoT): `controller.js` macht seine zwei `fetch` über injizierbare `checkText`/`addWord`-Callbacks (Default bleibt `fetch`), und `lib/editor-bundle.js` nimmt `controller.js` + `css/editor/spellcheck.css` + `icons.svg` ins OTA-Bundle auf (im Hauptrepo erledigt).

Bridge-Kanal **Swift → JS** (`callAsyncJavaScript` in `contentWorld: .page`): Die Facade stellt einen Event-Bus `window.__focusBridge.on(event, cb)` / `_receive(event, payload)` bereit. Swift sendet:
- `serverUpdate { pageId, html, baseUpdatedAt }` → saubere offene Seite wurde serverseitig aktualisiert → still neu laden.
- `openPage { pageId, html, baseUpdatedAt }` → nativer Picker hat eine Seite gewählt → im Editor öffnen.
- `closePage {}` → Buchwechsel: offene Seite schliessen → der Editor-Glue sichert den aktuellen Stand (local-first) und leert die Schreibfläche, damit der Text des alten Buchs nicht stehenbleibt. Der Swift-Kern öffnet danach den Seiten-Picker (`LibraryStore.selectBook` bei echtem Wechsel → `pickerOpenRequest`).
- `focusGranularity { granularity }` → Fokus-Stufe live umgeschaltet (CSS-Klasse `focus-mode--<value>`).
- `editorTypography { … }` → Typografie live umgeschaltet; der Boot-Glue setzt CSS-Custom-Properties auf `:root` + injiziert EIN `<style id="sw-native-typography">`, das `.focus-editor__content` überschreibt (Override-Schicht über dem unveränderten Editor-CSS — kein Fork).

Block-Merge (409): `window.__focusBridge._merge3(base, local, server)` lädt das gecachte `block-merge.js` dynamisch und liefert `{ merged, conflictCount }`. Der Swift-Kern ruft das beim 409-Push: `conflictCount == 0` → gemergtes HTML mit neuer Basis erneut pushen (still); `> 0` → Konflikt erfassen (Editor-Konflikt-UI). Merge-Ancestor (`base`) führt die SyncEngine als `serverBaseHtml` je Seite.

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

### Editor-Bundle (OTA) — `GET /content/editor-bundle.zip`

*(Server: erledigt, [routes/content.js](../../ClaudeProjects/schreibwerkstatt/routes/content.js) + [lib/editor-bundle.js](../../ClaudeProjects/schreibwerkstatt/lib/editor-bundle.js))*
- **Auth nötig** (Bearer `swd_…`, globaler Guard wie alle `/content`-Routen).
- Liefert ein **DEFLATE-ZIP** (JSZip) mit der JS-Import-Closure (`js/…`), den Focus-Editor-CSS (`css/…`) und `bundle-manifest.json` (`{ sourceCommit, jsFiles[], cssFiles[] }`). **Kein `index.html`** (Client-Glue, s. o.).
- **ETag** (`"sha256…"` über Commit + sortierte Datei-Hashes) + `If-None-Match` → **304** ohne Body. Der Client fragt bei jedem Online-Start konditional an.
- **Client-Seite:** [Web/EditorBundleStore.swift](schreibwerkstatt-focuseditor/Web/EditorBundleStore.swift) lädt (ETag aus Sidecar), entpackt mit [Web/MiniZip.swift](schreibwerkstatt-focuseditor/Web/MiniZip.swift) (bordeigener ZIP/DEFLATE-Reader — App ist sandboxed, kein `Process`/`unzip`, keine SPM-Dependency), schreibt `index.html` aus dem Manifest und tauscht den Cache **atomar**. Cache-Ort: `Application Support/schreibwerkstatt-focuseditor/web-cache/` (+ `web-cache.meta.json` für ETag/Commit).
- **Refresh-Timing:** Mit vorhandenem Cache startet der Editor sofort; der Refresh läuft still im Hintergrund und greift erst beim **nächsten** Start (kein Hot-Swap mitten im Schreiben → Datenverlust-Schutz). Ohne Cache: blockierender Erst-Download (UI-Lade-/Fehlerzustand in [ContentView.swift](schreibwerkstatt-focuseditor/ContentView.swift)).

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

**Ort des Codes:** [Sync/](schreibwerkstatt-focuseditor/Sync/) (Engine + State + Reachability + Models). Der konkrete Ablauf (Push/409-Merge/Pull/Delete-Reconcile, `applyServerPage`/`markPushed`-Semantik, Scene-Phase-Verdrahtung) steht in [ARCHITECTURE.md](ARCHITECTURE.md) §5.

- Inhalte fließen ausschließlich über die Content-Store-Semantik des Servers — kein Voll-Buch-`.swbook` für den Live-Sync (zu grob).

## Verzeichnislayout

App-Sources unter [schreibwerkstatt-focuseditor/](schreibwerkstatt-focuseditor/), nach Verantwortung gruppiert. Die Datei-für-Datei-Karte (welcher Typ wo, wer wen besitzt) steht in [ARCHITECTURE.md](ARCHITECTURE.md) §2–§10.

```
schreibwerkstatt-focuseditor/        App-Sources (Swift)
  *App.swift · AppCore.swift · ContentView.swift · AppToolbar.swift · WindowChromeController.swift
  Web/        WKWebView-Host + Bridge + OTA-Lader (EINZIGE Kopplungsschicht WebView ⇄ Swift)
  Store/      GRDB-LocalStore + Outbox
  Sync/       SyncEngine + Reachability + SyncState + SyncModels + SyncPreferences
  Auth/       Keychain + Device-Token + Login + APIClient + ServerConfig
  Content/    ContentAPI (Lese-Zugriff Buch-/Kapitel-Struktur, Server-Soll)
  Library/    LibraryStore + native Picker (BookPicker, PagePickerOverlay)
  Theme/      Appearance + Typography (Controller) + BrandColor + BrandFont
  Focus/      FocusController (lokale Fokus-Granularität)
  Writing/    WritingStatsStore (Live-Wortzahl/Lesezeit/Schreibziel/Tages-Delta)
  Conflict/   ConflictDiff (HTML→Absätze + absatzweiser Diff) + ConflictResolutionView (Nebeneinander-Sheet, informierte 409-Auflösung)
  Update/     UpdaterController (Sparkle-Auto-Update; Config in Config/Info.plist + Config/Focuseditor.entitlements)
  Settings/   SettingsView (⌘, — 7 Tabs)
  Localization/  Zweisprachigkeit de/en: Localization.swift (t()/tn() + L10nStore + LocalizationController) + mac-de.json/mac-en.json (gebündelt) + I18nBundleStore (OTA-Override)
```

**Einstellungen (alle gerätelokal, UserDefaults):** App-Sprache (de/en/System) + Server-URL + Lieblingsbuch (Allgemein) · Hell/Dunkel/System + Fokus-Granularität + Auto-Hide-Toolbar (Darstellung) · Schriftgrösse/-art, Zeilenhöhe, Spaltenbreite (measure), Papier-Ton (Typografie) · Wortzahl-Anzeige + Wort-Ziel pro Seite (Schreiben) · Poll-Kadenz/Pause/manueller Sync (Sync) · LanguageTool an-aus + Sprach-Override (Rechtschreibung) · Abmelden + App-Version/Update (Sparkle) + Editor-Bundle-Version/Update + Cache leeren (Konto). Editor-wirksame Werte (Typografie, Fokus) fliessen über die Bridge als CSS — **kein Editor-Fork**.

Der App-Sources-Ordner ist eine `PBXFileSystemSynchronizedRootGroup` (Xcode 16+) → neue Swift-Dateien kommen **automatisch** ins Target (kein pbxproj-Edit nötig).

**Editor-Cache (Laufzeit, nicht im Repo):** Das Editor-Build liegt **nicht** mehr im App-Paket, sondern wird per OTA gezogen und unter `~/Library/Application Support/schreibwerkstatt-focuseditor/web-cache/` gecacht (s. „Editor-Bundle (OTA)"). Es gibt **keinen** Build-Step und **kein** `web/`-Verzeichnis mehr.

## Harte Regeln

- **Kein Editor-Fork.** Editor-Logik, CSS und `block-merge.js` kommen aus dem Hauptrepo via OTA-Bundle (`GET /content/editor-bundle.zip`). Hier nur Bridge + Shell + Sync + Auth + OTA-Lader. Gecachten Output nie von Hand editieren.
- **WebView lädt nur lokal.** Niemals eine Server-URL in den `WKWebView` laden — die WebView liest ausschließlich aus dem lokalen Cache (`AppSchemeHandler`). Server-Kontakt (Sync **und** Bundle-Download) ausschließlich im Swift-Kern.
- **Local-first Writes.** Jeder Save geht zuerst in LocalStore + Outbox, erst danach (bei Konnektivität) zum Server. UI nie auf Netzwerk warten lassen.
- **Token nur im Keychain.** Device-Token niemals in UserDefaults, Plist, Logs oder Bridge-Messages an die WebView leaken. Die WebView braucht das Token nicht — Netzwerk macht Swift.
- **Konflikte über Block-Merge.** 409-Auflösung läuft über `block-merge.js` (3-Wege, `data-bid`), nicht über naives Last-Write-Wins. `data-bid`-Attribute nie strippen.
- **Datenverlust-Schutz vor allem.** Bei Auth-/Sync-Fehlern lokale Inhalte behalten; kein automatisches Verwerfen, kein Überschreiben ohne Merge.
- **Tastaturkürzel-Hilfe pflegen.** Wird ein Tastaturkürzel neu hinzugefügt, geändert oder entfernt (Swift `.keyboardShortcut` **oder** ein Editor-Shortcut, der für den Nutzer im Client greift), muss es in der Hilfe-Liste [ShortcutsHelpView.swift](schreibwerkstatt-focuseditor/ShortcutsHelpView.swift) (Help-Menü → „Tastaturkürzel", ⌘?) im selben Schritt aktualisiert werden. Die Liste ist die Single Source of Truth für die Nutzer-Hilfe — nie veralten lassen.
- **Lokalisierung (de/en) — kein hartkodierter UI-String.** Jeder nutzersichtbare Text läuft über `t("key")` (Plural: `tn(count, "baseKey")`) aus [Localization/Localization.swift](schreibwerkstatt-focuseditor/Localization/Localization.swift). Neue/geänderte Strings **immer** in **beide** gebündelten Kataloge [mac-de.json](schreibwerkstatt-focuseditor/Localization/mac-de.json) **und** [mac-en.json](schreibwerkstatt-focuseditor/Localization/mac-en.json) (Namespace `macclient.*`, flach, `{param}`-Platzhalter wie die Web-i18n). Fallback-Kette: `OTA[locale] → bundled[locale] → bundled["de"] → key`. Markennamen (z. B. „Schreibwerkstatt") bleiben literal. Die gebündelten Kataloge sind der Offline-Pflicht-Fallback; der Server-Override (`GET /content/macclient-i18n.json`, `I18nBundleStore`) ist optional und greift wie das Editor-Bundle erst beim **nächsten** Start. Die aktive Sprache: lokale Wahl (Settings → Allgemein) gewinnt; ohne lokale Wahl seedet `LocalizationController.seedFromServerIfNeeded()` aus dem Server-Profil (`/config` → `userSettings.locale`), sonst Systemsprache. Code-Kommentare auf Deutsch (wie Hauptrepo).
- **Nach jeder Swift-Änderung builden.** Nach jeder Anpassung an Swift-Code den Build laufen lassen (s. „Build & Run") und Fehler/Warnings zurückmelden, bevor es weitergeht. Nicht ungeprüft mehrere Änderungen stapeln.
- **Datei-Größe prüfen (Test).** Nach jeder Änderung an Swift-Quelldateien (neue Datei, Datei deutlich gewachsen) den Datei-Größen-Guard [SourceFileSizeTests.swift](schreibwerkstatt-focuseditorTests/SourceFileSizeTests.swift) laufen lassen (s. „Build & Run"). Er hält jede `.swift`-Datei unter **800 Zeilen** (Richtwert/Ziel eher 300–500). Schlägt er an → aufteilen (in Swift meist per `extension` über mehrere Dateien, Vorbild `SyncEngine[+Push/+Pull]`) **oder**, wenn die Größe bewusst gewollt ist (z. B. zusammenhängendes Template), mit Begründung in die `allowedOverLimit`-Allowlist im Test aufnehmen. Neue App-Dateien, die eine getestete Datei als Abhängigkeit braucht, müssen ins Test-Target (explizite Membership im pbxproj, s. [ARCHITECTURE.md](ARCHITECTURE.md) / `xctest`-Hinweis).

## Build & Run

- Xcode-Projekt: `schreibwerkstatt-focuseditor.xcodeproj`. Target: macOS (SwiftUI-App-Lifecycle).
- **Kein Bundle-Build-Step nötig** — das Editor-Build wird zur Laufzeit per OTA gezogen (s. „Editor-Bundle (OTA)"). Zum Testen muss der Server (Default `localhost:3737`) erreichbar und ein gültiges Device-Token eingeloggt sein.
- Abhängigkeiten: GRDB (SQLite) *(integriert, SPM `groue/GRDB.swift`, `upToNextMajor` ab 7.11.0)*; Sparkle (Auto-Update, **integriert**, SPM `sparkle-project/Sparkle`, `upToNextMajor` ab 2.6.0 — gekapselt in [Update/UpdaterController.swift](schreibwerkstatt-focuseditor/Update/UpdaterController.swift); Appcast via GitHub-„latest"-Release-Asset, Schlüssel/Flow s. [SIGNING.md](SIGNING.md) „Auto-Update (Sparkle)"). ZIP-Entpacken bewusst **ohne** Dependency (`MiniZip.swift` + `Compression`-Framework, sandbox-tauglich).
- **Build-Check nach jeder Swift-Änderung** (Pflicht, s. Harte Regeln):

  ```bash
  xcodebuild -scheme schreibwerkstatt-focuseditor -configuration Debug build
  ```

  Für kompakte Ausgabe `-quiet` anhängen. Verifiziert lauffähig am 2026-06-14 (`** BUILD SUCCEEDED **`).
- **Datei-Größen-Guard (Pflicht bei Source-Änderungen, s. Harte Regeln):**

  ```bash
  xcodebuild -scheme schreibwerkstatt-focuseditor -configuration Debug test \
    -only-testing:schreibwerkstatt-focuseditorTests/SourceFileSizeTests
  ```

  Prüft, dass keine `.swift`-Datei das 800-Zeilen-Limit überschreitet (Allowlist im Test). Die ganze Suite läuft mit `test` ohne `-only-testing`. Verifiziert grün am 2026-06-15 (58 Tests, `** TEST SUCCEEDED **`).
