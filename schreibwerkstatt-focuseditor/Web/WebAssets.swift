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
    static let handlerName = EditorBridge.handlerName

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

        // Editor meldet offene Seite + Dirty-Flag an Swift (Open-Page-Reload/-Schutz).
        reportState: (pageId, dirty) =>
          call('editorState', { pageId: pageId == null ? null : String(pageId), dirty: !!dirty }),

        // Rechtschreibprüfung (LanguageTool) — Proxy über den Swift-Kern. Die
        // WebView macht NIE direkten fetch; Settings (enabled/url/picky/rules)
        // liegen serverseitig und werden vom Proxy angewandt.
        spellcheckConfig: () => call('spellcheckConfig', {}),
        languagetoolCheck: (params) => call('languagetoolCheck', params || {}),
        dictionaryAdd: (params) => call('dictionaryAdd', params || {}),

        // Lokale Fokus-Granularität (paragraph/sentence/window-3/typewriter-only).
        // Boot-Pull; Live-Umschalten kommt zusätzlich als 'focusGranularity'-Event.
        focusGranularity: () => call('focusGranularity', {}),

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
          const m = await import('/js/editor/shared/block-merge.js');
          const res = m.mergeBlocks(baseHtml || '', localHtml || '', serverHtml || '');
          return { merged: m.mergedToHtml(res.merged), conflictCount: res.conflicts.length };
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
    static func indexHTML(cssFiles: [String], sourceCommit: String) -> String {
        let links = cssFiles
            .map { "  <link rel=\"stylesheet\" href=\"\($0)\">" }
            .joined(separator: "\n")
        return """
        <!doctype html>
        <html lang="de">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Schreibwerkstatt — Focus-Editor</title>
          <!-- GENERIERT vom EditorBundleStore aus dem OTA-Bundle (Quelle @\(sourceCommit)). Nicht von Hand editieren. -->
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
          </style>
        </head>
        <body>
          <!-- Mount-Punkt für den Standalone-Focus-Editor. -->
          <div id="mount"></div>
          <div id="boot-status">Lade Editor…</div>

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
                  let pages = [];
                  try { pages = await fb.list(); } catch (_) {}
                  const first = Array.isArray(pages) && pages.length ? pages[0] : null;
                  const id = first ? first.id : 'default';
                  let page = null;
                  try { page = await fb.load(id); } catch (_) {}
                  if (page) {
                    bases.set(String(page.id), page.updatedAt ?? null);
                    currentPageId = String(page.id);
                    currentBookId = (page.bookId != null) ? Number(page.bookId) : null;
                    return { id: page.id, name: page.pageName || page.title || 'Seite', html: page.html || '<p><br></p>' };
                  }
                  bases.set('default', null);
                  currentPageId = 'default';
                  currentBookId = null;
                  return { id: 'default', name: 'Neue Seite', html: '<p><br></p>' };
                },
                savePage: async ({ id, html }) => {
                  const base = bases.get(String(id)) ?? null;
                  const res = await fb.save(id, html, base);
                  if (res && res.updatedAt != null) bases.set(String(id), res.updatedAt);
                  return res;
                },
              };

              window.__standalone = await mountStandaloneFocus({ mount: document.getElementById('mount'), bridge });
              status.remove();
              fb.log?.('Standalone-Focus gemountet');

              // ── Seitenwechsel / Server-Frische (Swift → JS Event-Bus) ───────
              // Der native Picker (⌘O) und die SyncEngine heben Seiten über die
              // Bridge in den Editor. Ohne diese Abos passiert beim Auswählen
              // einer Seite NICHTS (Event ohne Listener) → kein Seitenwechsel.
              // Inhalt frisch aus dem LocalStore ziehen (offline-first), damit
              // name/bookId/updatedAt konsistent zur loadPage-Logik sind.
              async function applyPage(pageId, { save }) {
                // Beim Picker-Wechsel den aktuellen Stand zuerst sichern
                // (local-first): setPage verwirft den Autosave-Timer, sonst
                // gingen offene Änderungen der bisherigen Seite verloren.
                if (save) { try { await window.__standalone.save(); } catch (_) {} }
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
              }

              // Nativer Picker → andere Seite öffnen (vorher aktuellen Stand sichern).
              fb.on('openPage', (p) => {
                if (!p || p.pageId == null) return;
                applyPage(p.pageId, { save: true });
              });
              // Saubere offene Seite wurde serverseitig aktualisiert → still neu
              // laden (Swift sendet das nur für die nicht-dirty offene Seite, also
              // KEIN Save — der Server-Stand ist bereits die Quelle der Wahrheit).
              fb.on('serverUpdate', (p) => {
                if (!p || p.pageId == null) return;
                applyPage(p.pageId, { save: false });
              });

              // ── Fokus-Granularität live umschalten (Swift → JS) ─────────────
              // Spiegelt das Verhalten der SPA (editor-focus-card.js $watch):
              // Host-Feld setzen, CSS-Klasse tauschen, Fokus-Overlay neu rechnen.
              // Die Engine liest focusGranularity sonst nur beim enterFocusMode.
              function applyGranularity(g) {
                const valid = ['paragraph', 'sentence', 'window-3', 'typewriter-only'];
                const gran = valid.indexOf(g) >= 0 ? g : 'paragraph';
                const handle = window.__standalone;
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
                  const root = document.querySelector('.focus-editor__content');
                  if (mod && typeof mod.createSpellcheckController === 'function' && root) {
                    const I18N = {
                      'spellcheck.popover.ignore': 'Ignorieren',
                      'spellcheck.popover.add_to_dict': 'Zum Wörterbuch',
                      'spellcheck.popover.no_suggestions': 'Keine Vorschläge',
                      'spellcheck.popover.rule_info': 'Regel-Info',
                      'spellcheck.status.active': 'LanguageTool aktiv',
                      'spellcheck.status.disabled': 'LanguageTool deaktiviert',
                      'spellcheck.status.error': 'LanguageTool-Fehler',
                      'spellcheck.status.matches': '{n} Hinweise',
                      'spellcheck.status.no_matches': 'Keine Hinweise',
                      'spellcheck.extension_conflict.title': 'LanguageTool-Browser-Extension erkannt',
                    };
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
                      onApplyReplacement: (range, text) => {
                        if (!range) return;
                        try {
                          range.deleteContents();
                          range.insertNode(document.createTextNode(text));
                        } catch (_) { return; }
                        try {
                          const sel = window.getSelection();
                          sel?.removeAllRanges();
                          const r2 = document.createRange();
                          r2.setStartAfter(range.endContainer);
                          r2.collapse(true);
                          sel?.addRange(r2);
                        } catch (_) {}
                        root.dispatchEvent(new Event('input', { bubbles: true }));
                      },
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
