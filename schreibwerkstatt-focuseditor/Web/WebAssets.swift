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
              const bridge = {
                granularity: 'paragraph',
                loadPage: async () => {
                  let pages = [];
                  try { pages = await fb.list(); } catch (_) {}
                  const first = Array.isArray(pages) && pages.length ? pages[0] : null;
                  const id = first ? first.id : 'default';
                  let page = null;
                  try { page = await fb.load(id); } catch (_) {}
                  if (page) {
                    bases.set(String(page.id), page.updatedAt ?? null);
                    return { id: page.id, name: page.pageName || page.title || 'Seite', html: page.html || '<p><br></p>' };
                  }
                  bases.set('default', null);
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
