//
//  WebAssets+DevHarness.swift
//  schreibwerkstatt-focuseditor
//
//  Eigenständige Diagnose-Seite (`devHarnessHTML`) — testet den Bridge-Round-Trip
//  (load/save/list) ohne Editor. Wird via `loadHTMLString` geladen, solange (noch)
//  KEIN echtes Editor-Bundle vorliegt. Kein Produktions-Asset.
//

import Foundation

extension WebAssets {
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
