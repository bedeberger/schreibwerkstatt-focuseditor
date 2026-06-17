//
//  WebAssets.swift
//  schreibwerkstatt-focuseditor
//
//  In-Source-Web-Assets für die native Shell:
//   • `bridgeFacadeJS` — wird at-document-start in JEDE geladene Seite injiziert
//     (auch ins spätere Editor-Bundle) und stellt `window.__focusBridge` bereit.
//     Das ist das einzige JS-Primitiv, über das die WebView den Swift-Kern
//     erreicht. Der spätere Bridge-Host (die `setFocusHost(...)`-Implementierung,
//     entsteht zusammen mit `focus/standalone.js`) baut darauf auf.
//   • `devHarnessHTML` — eine eigenständige Diagnose-Seite, die die Bridge
//     (load/save/list) ausübt. Wird geladen, solange noch KEIN echtes
//     Editor-Bundle unter Resources/web/ vorliegt. Kein Produktions-Asset.
//
//  Das echte Editor-Bundle kommt per Build-Step aus dem Hauptrepo (CLAUDE.md);
//  diese Strings werden NICHT von Hand zu Editor-Code ausgebaut.
//

import Foundation

enum WebAssets {
    /// Name des WKScriptMessage-Handlers — Single Source of Truth. Hier (im
    /// dependency-freien Asset-Modul) verankert, damit `WebAssets` ohne den
    /// schweren `EditorBridge` (WebKit/LocalStore/APIClient) testbar/kompilierbar
    /// bleibt. `EditorBridge.handlerName` referenziert diesen Wert.
    static let handlerName = "swBridge"

    /// At-document-start injiziert. Definiert `window.__focusBridge.call(op, params)`
    /// → Promise mit dem Swift-Reply. Leitet zusätzlich `console.*` an den
    /// Swift-Logger weiter (Diagnose). Bewusst schlank — keine Editor-Logik.
    static let bridgeFacadeJS = """
    (function () {
      'use strict';
      const handler = window.webkit
        && window.webkit.messageHandlers
        && window.webkit.messageHandlers.\(handlerName);

      if (!handler) {
        console.warn('[focus-bridge] Swift-Handler nicht verfügbar — kein nativer Kontext?');
        return;
      }

      // Einziges Brücken-Primitiv: liefert ein Promise mit dem Swift-Reply.
      const call = (op, params) => handler.postMessage({ op: op, params: params || {} });

      window.__focusBridge = {
        call,
        load: (pageId) => call('load', { pageId }),
        save: (pageId, html, baseUpdatedAt) => call('save', { pageId, html, baseUpdatedAt }),
        list: (bookId) => call('list', bookId == null ? {} : { bookId }),
        log:  (message, level) => call('log', { message: String(message), level: level || 'info' }),

        // Zuletzt geöffnete Seite (gerätelokal, pro Buch) — Boot-Restore.
        // loadPage bevorzugt sie für das aktive Buch, fällt sonst auf die erste
        // Seite des Buchs zurück. Ohne bookId: globaler (legacy) Wert.
        lastOpenPage: (bookId) => call('lastOpenPage', bookId == null ? {} : { bookId }),

        // In der Toolbar gewähltes Buch (gerätelokal, pro Server). loadPage
        // skopiert die initiale Seitenauswahl darauf, damit beim Start nie eine
        // Seite aus einem anderen Buch geladen wird. { bookId } | { bookId: null }.
        activeBook: () => call('activeBook', {}),

        // Editor meldet offene Seite + Dirty-Flag an Swift (Open-Page-Reload/-Schutz).
        // bookId hängt mit, damit Swift die zuletzt geöffnete Seite PRO Buch merkt
        // (Boot-Restore ohne Buch-Verwechslung).
        reportState: (pageId, dirty, bookId) =>
          call('editorState', { pageId: pageId == null ? null : String(pageId),
                                dirty: !!dirty,
                                bookId: bookId == null ? null : Number(bookId) }),

        // Rechtschreibprüfung (LanguageTool) — Proxy über den Swift-Kern. Die
        // WebView macht NIE direkten fetch; Settings (enabled/url/picky/rules)
        // liegen serverseitig und werden vom Proxy angewandt.
        spellcheckConfig: () => call('spellcheckConfig', {}),
        languagetoolCheck: (params) => call('languagetoolCheck', params || {}),
        dictionaryAdd: (params) => call('dictionaryAdd', params || {}),

        // Lokale Fokus-Granularität (paragraph/sentence/window-3/typewriter-only).
        // Boot-Pull; Live-Umschalten kommt zusätzlich als 'focusGranularity'-Event.
        focusGranularity: () => call('focusGranularity', {}),

        // Lokale Editor-Typografie (Schriftgrösse/Zeilenhöhe/measure/Familie/
        // Papier-Ton) als CSS-fertiges Payload. Boot-Pull; Live-Umschalten kommt
        // zusätzlich als 'editorTypography'-Event.
        editorTypography: () => call('editorTypography', {}),

        // Editor-Verhalten (Auto-Save-Debounce) — Boot-Pull, wird an
        // mountStandaloneFocus({ autosaveMs }) durchgereicht.
        editorBehavior: () => call('editorBehavior', {}),

        // Lebende Schreibstatistik (Wörter/Zeichen) der offenen Seite an Swift
        // melden (Live-Stats + Schreibziel + Tages-Delta). Die pageId hängt mit,
        // damit Swift den „heute geschrieben"-Delta korrekt PRO Seite führt
        // (Tagesbaseline pro Seite). Feuert debounced bei Eingabe.
        reportStats: (words, chars, pageId) =>
          call('reportStats', { words, chars, pageId: pageId == null ? null : String(pageId) }),

        // Swift→JS Event-Bus. Der Editor-Host abonniert z. B. 'serverUpdate'
        // (saubere offene Seite wurde serverseitig aktualisiert → still neu laden).
        _handlers: {},
        on: function (event, cb) {
          (this._handlers[event] = this._handlers[event] || []).push(cb);
        },
        _receive: function (event, payload) {
          (this._handlers[event] || []).forEach(function (cb) {
            try { cb(payload); } catch (e) { console.error('[focus-bridge] handler', e); }
          });
        },

        // 3-Wege-Block-Merge über das gebündelte block-merge.js (ES-Modul,
        // dynamisch geladen). Von Swift via callAsyncJavaScript aufgerufen.
        // Wirft, wenn kein Bundle vorliegt (Dev-Harness) → Swift wertet das als Konflikt.
        _merge3: async function (baseHtml, localHtml, serverHtml) {
          // Relativer Specifier wie der restliche Boot-Glue (./js/…). Ein
          // root-absoluter Pfad (/js/…) bräche, sobald der Cache-Root nicht der
          // Origin-Root ist — und würde JEDEN 409 still zum harten Konflikt
          // degradieren. Konsistent halten zu standalone.js/controller.js unten.
          const m = await import('./js/editor/shared/block-merge.js');
          const res = m.mergeBlocks(baseHtml || '', localHtml || '', serverHtml || '');
          return { merged: m.mergedToHtml(res.merged), conflictCount: res.conflicts.length };
        },

        // Offenen Draft sofort persistieren (z. B. bei ⌘S). Der Editor-Autosave
        // läuft entprellt — ein frischer Tastenanschlag liegt also evtl. noch
        // nicht im LocalStore. `__standalone.save()` verwirft den Autosave-Timer
        // und schiebt den aktuellen Stand über die save-Op (→ LocalStore +
        // Outbox). AWAITABLE gehalten (Swift wartet darauf, bevor es den Sync
        // anstösst) — anders als der Fire-and-forget-Event-Bus (`_receive`).
        // Kein offener Editor / kein Bundle → still no-op (kein Wurf).
        _flushSave: async function () {
          const s = window.__standalone;
          if (s && typeof s.save === 'function') { await s.save(); }
          return true;
        },
      };

      // console → Swift-Log (nur Weiterleitung, Original bleibt erhalten).
      ['log', 'info', 'warn', 'error'].forEach((level) => {
        const orig = console[level].bind(console);
        console[level] = (...args) => {
          try { call('log', { level: level === 'warn' ? 'info' : level, message: args.join(' ') }); } catch (_) {}
          orig(...args);
        };
      });
    })();
    """

    /// Boot-/Bridge-HTML der Mac-Schale für das OTA-Editor-Bundle.
    ///
    /// Das `index.html` ist NICHT Teil des Server-Bundles (Editor-SSoT) — es ist
    /// Client-Glue (adaptiert die WKWebView-Bridge `window.__focusBridge` auf den
    /// standalone-Vertrag und mountet die Focus-Engine). Der EditorBundleStore
    /// schreibt es nach dem Entpacken in den Cache, mit den `<link>`-Tags aus den
    /// `cssFiles` des Bundle-Manifests (Reihenfolge = Link-Reihenfolge).
    ///
    /// Spiegelt die frühere Generierung in scripts/bundle-editor.mjs; bei
    /// Änderungen am Boot beide Stellen synchron halten (oder bundle-editor.mjs
    /// als reine Build-Referenz endgültig zurückbauen).
    /// Escaped einen String für die Verwendung in einem doppelt-gequoteten
    /// HTML-Attribut. Die CSS-Pfade stammen aus dem OTA-Bundle-Manifest
    /// (Trust-Grenze) — ein Pfad mit `"`/`<`/`>`/`&` würde sonst aus dem
    /// href-Attribut ausbrechen und Markup ins Boot-HTML injizieren, das mit
    /// Bridge-Zugriff im Page-World läuft.
    private static func htmlAttributeEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func indexHTML(cssFiles: [String], sourceCommit: String) -> String {
        let links = cssFiles
            .map { "  <link rel=\"stylesheet\" href=\"\(htmlAttributeEscaped($0))\">" }
            .joined(separator: "\n")
        return """
        <!doctype html>
        <html lang="de">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Schreibwerkstatt — Focus-Editor</title>
          <!-- GENERIERT vom EditorBundleStore aus dem OTA-Bundle (Quelle @\(htmlAttributeEscaped(sourceCommit))). Nicht von Hand editieren. -->
          <script>
            // Theme-Brücke: Die Editor-CSS schaltet Dark Mode NUR über
            // :root[data-theme="dark"] (theme-init.js aus dem Hauptrepo läuft
            // hier nicht). Die native AppearanceController setzt NSApp.appearance,
            // die WKWebView erbt sie → prefers-color-scheme stimmt. Wir spiegeln
            // diese Media-Query auf data-theme (vor erstem Paint = FOUC-sicher)
            // und folgen Live-Umschaltungen (System wie auch manuell Hell/Dunkel).
            (function () {
              var mq = window.matchMedia('(prefers-color-scheme: dark)');
              var sync = function () {
                document.documentElement.setAttribute('data-theme', mq.matches ? 'dark' : 'light');
              };
              sync();
              mq.addEventListener ? mq.addEventListener('change', sync) : mq.addListener(sync);
            })();
          </script>
        \(links)
          <style>
            html, body { margin: 0; height: 100%; background: var(--color-bg, #faf7f2); color: var(--color-text, #1f1c18); }
            #mount { height: 100vh; display: flex; flex-direction: column; }
            #boot-status { font: 13px/1.5 -apple-system, system-ui, sans-serif; padding: 24px; }
            .err { color: #c62828; }
            /* LanguageTool-Status-Badge ans Fenster-Eck pinnen. Der Editor-Controller
               positioniert .lt-badge per Inline-Style an die rechte Kante der
               .focus-editor__content (offsetLeft+offsetWidth). Da wir die Spalte
               zentriert + schmal (measure) auf breiter Fläche rendern, schwebte es
               sonst mitten über dem Text. position:fixed + !important überschreibt
               die Inline-Top/Left ohne Editor-Fork (Override-Schicht, CLAUDE.md). */
            .lt-badge {
              position: fixed !important;
              top: 12px !important;
              right: 16px !important;
              left: auto !important;
              transform: none !important;
            }
            /* Ruhige Leerfläche, wenn keine Seite offen ist (geschlossen / Boot
               ohne Seite). Liegt über der geleerten Schreibfläche und nimmt ihr
               jede Ablenkung: ein sanfter Verlauf in der Markenfläche + ein
               dezenter Hinweis, wie man eine Seite öffnet. Theme-treu über die
               Editor-CSS-Variablen (Light/Dark). Eingeblendet via body.sw-no-page. */
            #sw-empty {
              position: fixed; inset: 0; z-index: 30;
              display: none;
              flex-direction: column; align-items: center; justify-content: center;
              gap: 16px; padding: 48px; text-align: center;
              background:
                radial-gradient(135% 105% at 50% 14%,
                  color-mix(in srgb, var(--color-text, #1f1c18) 5%, transparent),
                  transparent 62%),
                var(--color-bg, #faf7f2);
              -webkit-user-select: none; user-select: none; cursor: default;
              animation: sw-empty-in .45s ease both;
            }
            body.sw-no-page #sw-empty { display: flex; }
            @keyframes sw-empty-in { from { opacity: 0 } to { opacity: 1 } }
            #sw-empty .sw-empty__mark {
              width: 46px; height: 46px;
              color: var(--color-text, #1f1c18); opacity: .26;
            }
            #sw-empty .sw-empty__title {
              margin: 0; font: 400 19px/1.4 var(--sw-font-family, ui-serif, Georgia, serif);
              color: var(--color-text, #1f1c18); opacity: .72;
            }
            #sw-empty .sw-empty__hint {
              margin: 0; font: 13px/1.5 -apple-system, system-ui, sans-serif;
              color: var(--color-text, #1f1c18); opacity: .42;
            }
            #sw-empty kbd {
              font: inherit; padding: 1px 7px; border-radius: 5px;
              background: color-mix(in srgb, var(--color-text, #1f1c18) 11%, transparent);
            }
          </style>
        </head>
        <body>
          <!-- Mount-Punkt für den Standalone-Focus-Editor. -->
          <div id="mount"></div>
          <div id="boot-status">Lade Editor…</div>

          <!-- Ruhige Leerfläche (keine Seite offen). Per body.sw-no-page eingeblendet. -->
          <div id="sw-empty">
            <svg class="sw-empty__mark" aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round">
              <path d="M6 3 H13 L19 9 V21 H6 Z"/>
              <path d="M13 3 V9 H19"/>
            </svg>
            <p class="sw-empty__title">Keine Seite geöffnet</p>
            <p class="sw-empty__hint">Eine Seite öffnen mit <kbd>⌘O</kbd></p>
          </div>

          <script type="module">
            // Boot der nativen Schale: adaptiert die WKWebView-Bridge (window.__focusBridge:
            // load/save/list) auf den standalone-Bridge-Vertrag (loadPage/savePage) und
            // mountet die Focus-Engine. Die Bridge-Facade liegt at-document-start bereit
            // (WKUserScript). Im reinen Browser (ohne Swift) fehlt sie → Hinweis statt Crash.
            const status = document.getElementById('boot-status');
            const fb = window.__focusBridge;
            try {
              if (!fb) throw new Error('window.__focusBridge fehlt (kein nativer Kontext)');
              const { mountStandaloneFocus } = await import('./js/editor/focus/standalone.js');

              // baseUpdatedAt je Seite mitführen (für den nächsten Push / 409-Basis).
              const bases = new Map();
              // Offene Seite + ihr Buch — die Rechtschreibprüfung reicht die
              // bookId an den Server, der daraus die Locale (de-CH) auflöst.
              let currentPageId = null;
              let currentBookId = null;
              // Hatte der Boot eine echte Seite zu laden? Wenn nein (leeres/
              // ungesynctes Buch), startet die App in der ruhigen Leerfläche
              // statt mit einer leeren Schreibfläche.
              let bootHadPage = false;

              // Ruhige Leerfläche ein-/ausblenden (keine Seite offen).
              const showEmpty = () => document.body.classList.add('sw-no-page');
              const hideEmpty = () => document.body.classList.remove('sw-no-page');

              // Cursor in die Schreibfläche setzen, damit eine frisch geöffnete
              // (oft leere) Seite sofort beschreibbar ist — ohne dass der Nutzer
              // erst hineinklicken muss. Der Standalone-Editor mountet direkt im
              // Fokus-Modus, setzt aber selbst keinen Caret (im Web-SPA kommt der
              // Nutzer schon mit gesetztem Cursor aus dem Edit-Modus). rAF, damit
              // enterFocusMode (läuft im $nextTick) den Container fertig aufgesetzt
              // hat, bevor wir die Selektion setzen.
              function focusEditor() {
                requestAnimationFrame(() => {
                  try {
                    const content = document.querySelector('.focus-editor.is-active .focus-editor__content')
                      || document.querySelector('.focus-editor__content');
                    if (!content) return;
                    content.focus();
                    const sel = document.getSelection();
                    if (!sel) return;
                    // Ans Ende des Inhalts setzen (leerer Absatz: einzige Position).
                    const range = document.createRange();
                    range.selectNodeContents(content);
                    range.collapse(false);
                    sel.removeAllRanges();
                    sel.addRange(range);
                  } catch (_) {}
                });
              }

              // Offene Seite + Dirty-Flag an den Swift-Kern melden (`editorState`).
              // Treibt die Seiten-Anzeige in der Toolbar UND die Sync-Logik:
              // Open-Page-Reload der sauberen offenen Seite + Datenverlust-Schutz
              // der dirty offenen Seite (SyncEngine liest openPageId/isDirty). Ohne
              // diesen Aufruf bliebe die Bridge-seitige openPageId immer null.
              // Nur bei echtem Zustandswechsel posten (keine Keystroke-Flut).
              let reportedPageId;
              let reportedDirty;
              function reportEditorState(pageId, dirty) {
                const pid = pageId == null ? null : String(pageId);
                if (pid === reportedPageId && dirty === reportedDirty) return;
                reportedPageId = pid;
                reportedDirty = dirty;
                try { fb.reportState(pid, dirty, currentBookId); } catch (_) {}
              }

              // Lokale Fokus-Granularität: beim Boot aus dem Swift-Kern ziehen
              // (UserDefaults-Wert), damit das initiale Mount schon die richtige
              // CSS-Klasse setzt. Live-Umschalten kommt später als Event.
              let initialGranularity = 'paragraph';
              try {
                const fc = await fb.focusGranularity();
                if (fc && fc.granularity) initialGranularity = fc.granularity;
              } catch (_) {}

              const bridge = {
                granularity: initialGranularity,
                loadPage: async () => {
                  // Auf das in der Toolbar gewählte Buch beschränken — sonst lüde
                  // die global gemerkte lastOpenPage (pro Server, nicht pro Buch)
                  // eine Seite aus einem anderen Buch, und der Editor zeigte ein
                  // anderes Buch als die Toolbar. Ohne aktives Buch (Erststart):
                  // ungefiltert wie bisher.
                  let bookId = null;
                  try {
                    const ab = await fb.activeBook();
                    if (ab && ab.bookId != null) bookId = ab.bookId;
                  } catch (_) {}
                  let pages = [];
                  try { pages = bookId != null ? await fb.list(bookId) : await fb.list(); } catch (_) {}
                  // Zuletzt geöffnete Seite bevorzugen (gerätelokal, PRO Buch
                  // gemerkt) — nur für das aktive Buch und nur, wenn sie noch in
                  // dessen Seitenliste steht (sonst gelöscht). Ohne aktives Buch
                  // (Erststart-Race, bevor die Toolbar ein Buch gewählt hat) NIE
                  // restoren — sonst öffnete sich eine Seite aus einem anderen
                  // Buch. Fallback: erste Seite des Buchs.
                  let id = null;
                  if (bookId != null) {
                    try {
                      const last = await fb.lastOpenPage(bookId);
                      if (last && last.pageId != null) {
                        const lid = String(last.pageId);
                        if (Array.isArray(pages) && pages.some((p) => String(p.id) === lid)) id = lid;
                      }
                    } catch (_) {}
                  }
                  if (id == null) {
                    const first = Array.isArray(pages) && pages.length ? pages[0] : null;
                    id = first ? first.id : 'default';
                  }
                  let page = null;
                  try { page = await fb.load(id); } catch (_) {}
                  if (page) {
                    bases.set(String(page.id), page.updatedAt ?? null);
                    currentPageId = String(page.id);
                    currentBookId = (page.bookId != null) ? Number(page.bookId) : null;
                    bootHadPage = true;
                    return { id: page.id, name: page.pageName || page.title || 'Seite', html: page.html || '<p><br></p>' };
                  }
                  bases.set('default', null);
                  currentPageId = 'default';
                  currentBookId = null;
                  bootHadPage = false;
                  return { id: 'default', name: 'Neue Seite', html: '<p><br></p>' };
                },
                savePage: async ({ id, html }) => {
                  // „Geschlossene" (leere) Seite nach einem Buchwechsel nie
                  // persistieren — sonst legte ein Autosave-Tick einen Junk-
                  // Eintrag mit leerer id an. Ebenso die 'default'-Platzhalter-
                  // Seite (Boot-Fallback bei leerem/ungesynctem Buch): sie ist
                  // kein echter Datensatz, hat kein Buch & keine Server-Basis →
                  // würde sonst als nie-pushbarer „default"-Konflikt landen.
                  if (id == null || id === '' || id === 'default') return null;
                  const base = bases.get(String(id)) ?? null;
                  const res = await fb.save(id, html, base);
                  if (res && res.updatedAt != null) bases.set(String(id), res.updatedAt);
                  reportEditorState(id, false);   // gespeichert → nicht mehr dirty
                  return res;
                },
              };

              // Auto-Save-Debounce (lokale Vorliebe) beim Mount durchreichen.
              // mountStandaloneFocus nutzt den Editor-Default (1500 ms), wenn
              // autosaveMs fehlt — darum nur setzen, wenn ein gültiger Wert kommt.
              let autosaveMs;
              try {
                const eb = await fb.editorBehavior();
                if (eb && Number.isFinite(Number(eb.autosaveMs))) autosaveMs = Number(eb.autosaveMs);
              } catch (_) {}

              const mountOpts = { mount: document.getElementById('mount'), bridge };
              if (autosaveMs != null) mountOpts.autosaveMs = autosaveMs;
              window.__standalone = await mountStandaloneFocus(mountOpts);
              status.remove();
              fb.log?.('Standalone-Focus gemountet');

              // Initial geöffnete Seite (loadPage) an Swift melden → Toolbar-Titel
              // steht ab Boot, nicht erst nach dem ersten Picker-Wechsel. Ohne
              // echte Seite (leeres/ungesynctes Buch) startet die App in der
              // ruhigen Leerfläche statt mit einer leeren Schreibfläche.
              if (bootHadPage) {
                reportEditorState(currentPageId, false);
                focusEditor();   // Cursor in die geladene Seite setzen
              } else {
                currentPageId = null;
                showEmpty();
                reportEditorState(null, false);
              }
              // Tastatureingaben markieren die offene Seite dirty (Datenverlust-
              // Schutz im Sync). Listener am Mount-Container (überlebt setPage,
              // das den Content-Knoten austauscht); 'input' bubbelt aus dem
              // contenteditable hoch.
              const mountEl = document.getElementById('mount');
              if (mountEl) mountEl.addEventListener('input', () => {
                if (currentPageId) reportEditorState(currentPageId, true);
              });

              // ── Seitenwechsel / Server-Frische (Swift → JS Event-Bus) ───────
              // Der native Picker (⌘O) und die SyncEngine heben Seiten über die
              // Bridge in den Editor. Ohne diese Abos passiert beim Auswählen
              // einer Seite NICHTS (Event ohne Listener) → kein Seitenwechsel.
              // Inhalt frisch aus dem LocalStore ziehen (offline-first), damit
              // name/bookId/updatedAt konsistent zur loadPage-Logik sind.
              async function applyPage(pageId, { save, focus }) {
                // Beim Picker-Wechsel den aktuellen Stand zuerst sichern
                // (local-first): setPage verwirft den Autosave-Timer, sonst
                // gingen offene Änderungen der bisherigen Seite verloren.
                if (save) { try { await window.__standalone.save(); } catch (_) {} }
                hideEmpty();   // wieder eine Seite offen → ruhige Leerfläche weg
                let page = null;
                try { page = await fb.load(String(pageId)); } catch (_) {}
                bases.set(String(pageId), page ? (page.updatedAt ?? null) : null);
                currentPageId = String(pageId);
                currentBookId = (page && page.bookId != null) ? Number(page.bookId) : null;
                window.__standalone.setPage({
                  id: pageId,
                  name: (page && (page.pageName || page.title)) || 'Seite',
                  html: (page && page.html != null) ? page.html : '<p><br></p>',
                });
                // Neu eingespielte Seite ist sauber → Swift/Toolbar nachziehen.
                reportEditorState(String(pageId), false);
                // Stats nach dem Seitenwechsel neu zählen (setPage feuert kein input).
                try { window.__countStats && window.__countStats(); } catch (_) {}
                // Beim aktiven Öffnen (Picker) Cursor setzen — beim stillen
                // Server-Refresh NICHT (würde den Fokus aus Toolbar/anderer App klauen).
                if (focus) focusEditor();
              }

              // Inline-Formatierung über das Format-Menü (Swift → JS). Spiegelt
              // exakt die nativen ⌘B/⌘I/⌘U des contenteditable-Editors:
              // document.execCommand auf der aktuellen Auswahl. Vorher die aktive
              // Schreibfläche fokussieren, damit der Befehl greift, auch wenn der
              // Fokus formal beim Menü lag (die Textauswahl bleibt dabei erhalten).
              fb.on('format', (p) => {
                const cmd = p && p.command;
                if (!cmd) return;
                try {
                  const content = document.querySelector('.focus-editor.is-active .focus-editor__content')
                    || document.querySelector('.focus-editor__content');
                  if (content) content.focus();
                  document.execCommand(cmd, false, null);
                } catch (e) { console.error('[focus-bridge] format', e); }
              });

              // Nativer Picker → andere Seite öffnen (vorher aktuellen Stand sichern).
              fb.on('openPage', (p) => {
                if (!p || p.pageId == null) return;
                applyPage(p.pageId, { save: true, focus: true });
              });
              // Saubere offene Seite wurde serverseitig aktualisiert → still neu
              // laden (Swift sendet das nur für die nicht-dirty offene Seite, also
              // KEIN Save — der Server-Stand ist bereits die Quelle der Wahrheit).
              fb.on('serverUpdate', (p) => {
                if (!p || p.pageId == null) return;
                applyPage(p.pageId, { save: false });
              });
              // Seite schliessen (Buchwechsel ODER bewusst über die Toolbar):
              // aktuellen Stand sichern (local-first), die Schreibfläche leeren
              // und die ruhige Leerfläche einblenden. Swift öffnet danach den
              // Picker. Kein Datenverlust — der Stand wurde vorher gespeichert.
              fb.on('closePage', async () => {
                try { await window.__standalone.save(); } catch (_) {}
                currentPageId = null;
                currentBookId = null;
                try {
                  window.__standalone.setPage({ id: '', name: '', html: '<p><br></p>' });
                } catch (_) {}
                showEmpty();
                reportEditorState(null, false);
                try { window.__countStats && window.__countStats(); } catch (_) {}
              });

              // ── Fokus-Granularität live umschalten (Swift → JS) ─────────────
              // Bevorzugt den öffentlichen Standalone-Hook `setGranularity` (ab
              // dem Bundle, das ihn mitliefert) — er kapselt Klassentausch +
              // Overlay-Recompute in der Engine. Fallback (älteres gecachtes
              // Bundle ohne den Hook): das Verhalten lokal nachbilden, inkl. des
              // internen `_focusUpdateActive`-Aufrufs. Greift erst, bis der OTA-
              // Refresh den Hook nachzieht.
              function applyGranularity(g) {
                const handle = window.__standalone;
                if (handle && typeof handle.setGranularity === 'function') {
                  handle.setGranularity(g);
                  return;
                }
                const valid = ['paragraph', 'sentence', 'window-3', 'typewriter-only'];
                const gran = valid.indexOf(g) >= 0 ? g : 'paragraph';
                if (handle && handle.host) handle.host.focusGranularity = gran;
                const focusEl = document.querySelector('.focus-editor');
                if (focusEl) {
                  focusEl.classList.remove(
                    'focus-mode--paragraph', 'focus-mode--sentence',
                    'focus-mode--window-3', 'focus-mode--typewriter-only');
                  focusEl.classList.add('focus-mode--' + gran);
                }
                try { handle && handle.controller && handle.controller._focusUpdateActive(false); } catch (_) {}
              }
              fb.on('focusGranularity', (p) => {
                if (p && p.granularity) applyGranularity(p.granularity);
              });

              // ── Editor-Typografie (Schriftgrösse/Zeilenhöhe/measure/…) ──────
              // Override-Schicht ÜBER dem unveränderten Editor-CSS (kein Fork):
              // CSS-Custom-Properties auf :root + EIN persistentes <style>, das
              // den Editor-Content überschreibt. Überlebt setPage (greift nicht
              // in den Content-Baum ein). Werte kommen CSS-fertig aus Swift.
              function applyTypography(t) {
                if (!t) return;
                const root = document.documentElement;
                if (t.fontSize)   root.style.setProperty('--sw-font-size', t.fontSize);
                if (t.lineHeight) root.style.setProperty('--sw-line-height', t.lineHeight);
                if (t.measure)    root.style.setProperty('--sw-measure', t.measure);
                if (t.fontFamily) root.style.setProperty('--sw-font-family', t.fontFamily);
                // Papier-Ton: null = keine Überschreibung (System-/Theme-Fläche).
                if (t.paperBg)   root.style.setProperty('--sw-paper-bg', t.paperBg);
                else             root.style.removeProperty('--sw-paper-bg');
                if (t.paperText) root.style.setProperty('--sw-paper-text', t.paperText);
                else             root.style.removeProperty('--sw-paper-text');
                root.setAttribute('data-sw-paper', (t.paperBg ? 'custom' : 'system'));
                // Fokus-Abdunklung: null = Editor-Default (kein Override, theme-
                // korrekt); sonst Opazität der nicht-aktiven Absätze überschreiben.
                if (t.focusDim != null) {
                  root.style.setProperty('--sw-focus-dim', t.focusDim);
                  root.setAttribute('data-sw-dim', 'custom');
                } else {
                  root.style.removeProperty('--sw-focus-dim');
                  root.removeAttribute('data-sw-dim');
                }

                let style = document.getElementById('sw-native-typography');
                if (!style) {
                  style = document.createElement('style');
                  style.id = 'sw-native-typography';
                  style.textContent = [
                    '.focus-editor__content {',
                    '  font-size: var(--sw-font-size, 19px) !important;',
                    '  line-height: var(--sw-line-height, 1.7) !important;',
                    '  font-family: var(--sw-font-family, ui-serif, Georgia, serif) !important;',
                    '  max-width: var(--sw-measure, none) !important;',
                    '  margin-inline: auto !important;',
                    // Schreib-Caret in Marken-Gold — ein dezenter Identitäts-
                    // Akzent genau dort, wo geschrieben wird. Ein Ton, der auf
                    // hellem wie dunklem Papier trägt (kein Theme-Switch nötig).
                    '  caret-color: #b08d3f !important;',
                    '}',
                    // Papier-Ton nur, wenn gesetzt — sonst bleibt die native,
                    // transparente Brand-Fläche (Light/Dark) sichtbar.
                    ':root[data-sw-paper="custom"] body,',
                    ':root[data-sw-paper="custom"] .focus-editor {',
                    '  background: var(--sw-paper-bg) !important;',
                    '  color: var(--sw-paper-text) !important;',
                    '}',
                    // Fokus-Abdunklung: überschreibt NUR die Variable, die der
                    // Editor selbst liest (focus-mode.css: `--focus-dim-opacity`
                    // auf .focus-editor, ausgewertet an den gedimmten Blöcken) —
                    // statt den Dim-Selektor zu replizieren. Ändert das Hauptrepo
                    // welche Blöcke dimmen, folgt der Override automatisch (keine
                    // Kopplung an CSS-Interna). Spezifität (0,2,0) schlägt die
                    // Basisregel .focus-editor (0,1,0); greift nur bei data-sw-dim.
                    ':root[data-sw-dim="custom"] .focus-editor {',
                    '  --focus-dim-opacity: var(--sw-focus-dim) !important;',
                    '}',
                    // Sentence-Modus-Dim an denselben Override koppeln. Der
                    // Block-Dim ist Opazität auf der Papier-Textfarbe; der
                    // Sentence-Dim MUSS eine Farbe sein (Custom Highlight API
                    // kennt kein opacity). color-mix rekonstruiert dieselbe
                    // effektive Farbe: Papier-/Theme-Text bei der Dim-Opazität.
                    // Ohne das bliebe der Sentence-Dim auf dem hartcodierten
                    // Token (--color-focus-sentence-dim) stehen und passte bei
                    // custom Papier/Dim nicht zum Block-Dim. Token-Fallback
                    // greift weiter, solange weder Papier noch Dim custom sind.
                    ':root[data-sw-dim="custom"] ::highlight(focus-sentence-dim) {',
                    '  color: color-mix(in srgb, var(--color-text) calc(var(--sw-focus-dim) * 100%), transparent);',
                    '}',
                    ':root[data-sw-paper="custom"] ::highlight(focus-sentence-dim) {',
                    '  color: color-mix(in srgb, var(--sw-paper-text, var(--color-text)) calc(var(--sw-focus-dim, 0.35) * 100%), transparent);',
                    '}',
                  ].join('\\n');
                  document.head.appendChild(style);
                }
              }
              fb.on('editorTypography', (t) => applyTypography(t));
              // Boot-Pull: initiale Typografie ziehen und anwenden.
              try { applyTypography(await fb.editorTypography()); } catch (_) {}

              // ── Lebende Schreibstatistik (Wörter/Zeichen) ───────────────────
              // Zählt den Text der offenen Seite und meldet ihn debounced an
              // Swift (Toolbar-Stats + Schreibziel). Liest .focus-editor__content
              // (Root der Schreibfläche, denselben Knoten nutzt die Spellcheck).
              (function () {
                let statsTimer = null;
                function countAndReport() {
                  const root = document.querySelector('.focus-editor__content');
                  const text = root ? (root.innerText || root.textContent || '') : '';
                  const trimmed = text.trim();
                  const words = trimmed ? trimmed.split(/\\s+/).length : 0;
                  const chars = text.replace(/\\u00a0/g, ' ').length;
                  try { fb.reportStats(words, chars, currentPageId); } catch (_) {}
                }
                window.__countStats = countAndReport;
                // Debounced bei Eingabe (input bubblet vom Content nach oben).
                document.addEventListener('input', function () {
                  if (statsTimer) clearTimeout(statsTimer);
                  statsTimer = setTimeout(countAndReport, 400);
                }, true);
                // Initiale Zählung (nach dem ersten Mount/loadPage).
                setTimeout(countAndReport, 150);
              })();

              // ── Rechtschreibprüfung (LanguageTool) ──────────────────────────
              // Wiederverwendet den unveränderten Editor-Controller aus dem
              // Hauptrepo (kein Fork). Statt direktem fetch laufen Prüfung +
              // Wörterbuch über die Bridge → Swift-Kern → Server-Proxy. Greift
              // nur, wenn LT serverseitig aktiv ist UND das Bundle den Controller
              // mitliefert; sonst still übersprungen (degradiert sauber, offline
              // ohnehin kein Prüf-Roundtrip — kein Offline-Kern-Inhalt).
              try {
                const cfg = await fb.spellcheckConfig();
                if (cfg && cfg.enabled) {
                  const mod = await import('./js/cards/editor-spellcheck/controller.js');
                  // Range-Mutation + Caret-Restore aus dem gebündelten Helper
                  // (geteilt mit dem SPA-Dispatcher des Hauptrepos) — keine
                  // Client-Kopie der Caret-Logik. Kommt per OTA-Bundle.
                  const { applySpellcheckReplacement } = await import('./js/editor/shared/apply-replacement.js');
                  const root = document.querySelector('.focus-editor__content');
                  if (mod && typeof mod.createSpellcheckController === 'function' && root) {
                    // Popover-/Status-Strings kommen lokalisiert (de/en) über die
                    // Bridge (cfg.i18n, aus t()) — kein hartkodierter UI-String.
                    // Fallback auf den rohen Key, falls der Controller einen Key
                    // anfragt, den die Bridge (noch) nicht liefert.
                    const I18N = (cfg && cfg.i18n) || {};
                    const ctl = mod.createSpellcheckController({
                      root,
                      scrollContainer: root,            // .focus-editor__content ist Root UND Scroller
                      getHtml: () => root.innerHTML,
                      editorKind: 'focus',
                      getBookLocale: () => 'auto',      // Server löst Locale via bookId auf
                      getBookId: () => currentBookId,
                      getPageId: () => currentPageId,
                      isEnabled: () => true,
                      getDebounceMs: () => Number(cfg.debounceMs) || 1500,
                      i18n: (k) => I18N[k] || k,
                      onApplyReplacement: (range, text) => applySpellcheckReplacement(range, text),
                      // Transport über die Bridge (kein direkter fetch).
                      checkText: async ({ text, language, bookId, pageId }) => {
                        const res = await fb.languagetoolCheck({
                          text, language, bookId,
                          pageId: pageId == null ? null : String(pageId),
                        });
                        if (res && res.disabled) return { disabled: true };
                        return { matches: (res && res.matches) || [] };
                      },
                      addWord: async ({ word, bookId, lang }) => {
                        const res = await fb.dictionaryAdd({ word, bookId, lang });
                        return !!(res && res.ok);
                      },
                    });
                    ctl.attach();
                    window.__spellcheck = ctl;
                    fb.log?.('Rechtschreibprüfung aktiv');
                  }
                }
              } catch (e) {
                fb.log?.('Rechtschreibprüfung nicht verfügbar: ' + (e && e.message ? e.message : e), 'info');
              }
            } catch (e) {
              status.className = 'err';
              status.textContent = 'Boot-Fehler: ' + (e && e.message ? e.message : e);
              fb?.log?.('Boot-Fehler: ' + e, 'error');
              console.error(e);
            }
          </script>
        </body>
        </html>
        """
    }

    /// Eigenständige Diagnose-Seite — testet den Bridge-Round-Trip ohne Editor.
    /// Wird via `loadHTMLString` geladen (kein Resource-Bundling nötig).
    static let devHarnessHTML = """
    <!doctype html>
    <html lang="de">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Bridge-Harness</title>
      <style>
        :root { color-scheme: light dark; }
        body {
          font: 14px/1.5 -apple-system, system-ui, sans-serif;
          margin: 0; padding: 24px;
          background: #faf7f2; color: #1f1c18;
        }
        @media (prefers-color-scheme: dark) {
          body { background: #1a1816; color: #e6e2d9; }
          textarea, .log { background: #2a2722; color: #e6e2d9; border-color: #524d46; }
        }
        h1 { font: 600 20px/1.2 ui-serif, Georgia, serif; margin: 0 0 4px; }
        .sub { color: #9a7f3e; margin: 0 0 20px; font-size: 12px; letter-spacing: .04em; text-transform: uppercase; }
        textarea {
          width: 100%; box-sizing: border-box; min-height: 120px; padding: 10px;
          border: 1px solid #b8aea2; border-radius: 8px; background: #fff; color: inherit;
          font: 14px/1.5 ui-monospace, SFMono-Regular, monospace; resize: vertical;
        }
        .row { display: flex; gap: 8px; flex-wrap: wrap; margin: 12px 0; align-items: center; }
        button {
          font: 500 13px/1 system-ui, sans-serif; padding: 8px 14px;
          border: 0; border-radius: 8px; background: #1e3a5f; color: #fff; cursor: pointer;
        }
        button:hover { background: #16293d; }
        input { padding: 7px 10px; border: 1px solid #b8aea2; border-radius: 8px; background: transparent; color: inherit; }
        .log {
          margin-top: 16px; padding: 12px; border: 1px solid #b8aea2; border-radius: 8px;
          background: #fff; font: 12px/1.5 ui-monospace, monospace; white-space: pre-wrap;
          min-height: 80px; max-height: 280px; overflow: auto;
        }
        .ok { color: #2e7d32; } .err { color: #c62828; }
      </style>
    </head>
    <body>
      <h1>Schreibwerkstatt — Bridge-Harness</h1>
      <p class="sub">Diagnose · kein Editor-Bundle geladen</p>

      <div class="row">
        <label>pageId <input id="pageId" value="dev-page-1"></label>
        <button id="btnLoad">load</button>
        <button id="btnSave">save</button>
        <button id="btnList">list</button>
      </div>

      <textarea id="html" placeholder="HTML der Seite…"><p data-bid="b1">Hallo aus der Bridge-Harness.</p></textarea>

      <div class="log" id="log">Bereit.\\n</div>

      <script>
        const $ = (id) => document.getElementById(id);
        const logEl = $('log');
        const stamp = () => new Date().toLocaleTimeString();
        function logLine(msg, cls) {
          const span = document.createElement('span');
          if (cls) span.className = cls;
          span.textContent = `[${stamp()}] ${msg}\\n`;
          logEl.appendChild(span);
          logEl.scrollTop = logEl.scrollHeight;
        }

        const bridge = window.__focusBridge;
        if (!bridge) {
          logLine('FEHLER: window.__focusBridge fehlt — Facade nicht injiziert.', 'err');
        } else {
          logLine('Bridge verfügbar: ' + Object.keys(bridge).join(', '), 'ok');
          // Nativer Picker → Swift `openPage` → hier: Seite übernehmen (Diagnose).
          bridge.on('openPage', (p) => {
            $('pageId').value = p.pageId == null ? '' : p.pageId;
            if (p.html != null) $('html').value = p.html;
            logLine('openPage ← ' + p.pageId, 'ok');
          });
        }

        async function run(label, fn) {
          try {
            const res = await fn();
            logLine(label + ' → ' + JSON.stringify(res), 'ok');
          } catch (e) {
            logLine(label + ' ✗ ' + (e && e.message ? e.message : e), 'err');
          }
        }

        $('btnLoad').onclick = () => run('load', () => bridge.load($('pageId').value));
        $('btnSave').onclick = () => run('save', () => bridge.save($('pageId').value, $('html').value, null));
        $('btnList').onclick = () => run('list', () => bridge.list());
      </script>
    </body>
    </html>
    """
}
