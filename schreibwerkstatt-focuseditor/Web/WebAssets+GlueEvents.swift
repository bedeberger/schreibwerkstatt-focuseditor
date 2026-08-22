//
//  WebAssets+GlueEvents.swift
//  schreibwerkstatt-focuseditor
//
//  Der Event-Teil des Boot-Glues: Seite laden/wechseln/schliessen, stiller
//  Server-Refresh, Anführungszeichen normalisieren — die Gegenstellen zu den
//  Swift→JS-Events auf dem Bus `window.__focusBridge.on(...)`.
//
//  Teil des EINEN Boot-Moduls in [WebAssets+IndexHTML.swift](WebAssets+IndexHTML.swift):
//  die Fragmente teilen sich einen JS-Scope (`fb`, `currentPageId`, die Helfer)
//  und werden dort in fester Reihenfolge zusammengesetzt. Aufgeteilt, weil die
//  eine Datei über 1200 Zeilen gewachsen und der einzige Eintrag in der
//  Allowlist des Zeilen-Guards war — nicht, weil die Teile unabhängig wären.
//  Reihenfolge und Einrückung sind darum bindend; `WebAssetsSyntaxTests` lässt
//  `node --check` über das zusammengesetzte Ergebnis laufen.
//

import Foundation

extension WebAssets {
    /// Seitenwechsel + Swift→JS-Events — Fragment des Boot-Moduls (s. Kopfdoku).
    static let glueEventsJS = """
              // ── Seitenwechsel / Server-Frische (Swift → JS Event-Bus) ───────
              // Der native Picker (⌘O) und die SyncEngine heben Seiten über die
              // Bridge in den Editor. Ohne diese Abos passiert beim Auswählen
              // einer Seite NICHTS (Event ohne Listener) → kein Seitenwechsel.
              // Inhalt frisch aus dem LocalStore ziehen (offline-first), damit
              // name/bookId/updatedAt konsistent zur loadPage-Logik sind.
              async function applyPage(pageId, { save, focus }) {
                // Hatte die Schreibfläche gerade den Fokus? (für den stillen
                // Server-Refresh: dann Caret in-place wiederherstellen, statt ihn
                // beim setPage-DOM-Tausch lautlos wegspringen zu lassen.)
                const prev = activeContent();
                const wasFocused = !!(prev && prev.contains(document.activeElement));
                // Caret der bisher offenen Seite merken (Session), BEVOR setPage
                // den Content-Knoten austauscht.
                saveCaret(currentPageId);
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
                // Undo gehört ab jetzt zur NEUEN Seite: WebKits Undo-Stack hängt
                // an der WebView, nicht am Inhalt — die Einträge der vorigen Seite
                // würden sonst als wirkungslose „Widerrufen"-Schritte stehenbleiben.
                clearUndoSoon();
                resetTextLen();
                // Stats nach dem Seitenwechsel neu zählen (setPage feuert kein input).
                try { window.__countStats && window.__countStats(); } catch (_) {}
                // Caret-Strategie:
                //  - Picker-Öffnen (focus:true): aktiv fokussieren, gemerkte
                //    Position wiederherstellen, sonst ans Ende.
                //  - Stiller Server-Refresh (focus undefined): NUR wenn die
                //    Schreibfläche schon den Fokus hatte, Caret in-place
                //    wiederherstellen — kein Fokus-Diebstahl aus Toolbar/anderer
                //    App, aber auch kein lautloses Caret-Wegspringen beim Sync-Tick.
                if (focus || wasFocused) {
                  const stored = caretByPage.get(String(pageId));
                  focusEditor(typeof stored === 'number' ? { caretOffset: stored } : undefined);
                }
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
                  const content = activeContent();
                  // preventScroll: der Fokus-Rückholer darf die Ansicht nicht
                  // verschieben (WebKit deckt die Auswahl sonst unten-ausgerichtet
                  // auf — ein Sprung mitten im Formatieren).
                  if (content) content.focus({ preventScroll: true });
                  document.execCommand(cmd, false, null);
                } catch (e) { console.error('[focus-bridge] format', e); }
              });

              // ── Widerrufen / Wiederherstellen (Swift → JS) ──────────────────
              // Der gebündelte Editor führt seine EIGENE, entprellte
              // Snapshot-Historie (SSoT `shared/edit-history.js`) und fängt ⌘Z in
              // der Seite selbst ab. In dieser Schale erreicht die Taste die
              // WebView nie — das Menü-Kürzel greift app-weit vorher —, darum
              // löst der Menüpunkt die Aktion über dieses Event aus (wie das
              // Format-Menü). Das Restore feuert selbst ein `input`-Event mit
              // `inputType: historyUndo/historyRedo`; daran hängen Dirty-Flag,
              // Autosave, Statistik und der Hinweis-Banner (s. noticeHistoryEdit).
              //
              // Älteres gecachtes Bundle ohne die Handle-API: dann bleibt nur
              // WebKits grober Stack (`execCommand`) — besser als ein totes ⌘Z.
              // Der nächste Start zieht das neue Bundle und damit die feine
              // Körnung.
              fb.on('history', (p) => {
                const action = p && p.action === 'redo' ? 'redo' : 'undo';
                try {
                  const content = activeContent();
                  if (content) content.focus({ preventScroll: true });
                  const handle = window.__standalone;
                  if (handle && typeof handle[action] === 'function') {
                    handle[action]();
                    return;
                  }
                  document.execCommand(action, false, null);
                } catch (e) {
                  fb.log?.('History-Aktion: ' + (e && e.message ? e.message : e), 'info');
                }
              });

              // ── Anführungszeichen normalisieren (Swift → JS) ────────────────
              // Zieht die typografischen Anführungszeichen der offenen Seite auf
              // den Buch-Stil (de-CH → «», de-DE → „" …). Nutzt die fetch-freien
              // Primitive des gebündelten quote-normalize.js (resolveQuoteStyle +
              // normalizeQuotes); die Buch-Locale kommt aus Swift (Server), weil
              // der modulinterne fetch('/booksettings/…') in der lokalen WebView
              // ins Leere liefe. normalizeQuotes mutiert direkt das DOM (kein
              // input-Event) → danach synthetisch ein input feuern (markiert
              // dirty, treibt Autosave + Stats) und sofort local-first sichern.
              // Fehlt das Modul (älteres gecachtes Bundle), wird still degradiert.
              fb.on('normalizeQuotes', async (p) => {
                if (!currentPageId) return;   // keine echte Seite offen
                try {
                  const content = activeContent();
                  if (!content) return;
                  const mod = await import('./js/editor/shared/quote-normalize.js');
                  if (!mod || typeof mod.normalizeQuotes !== 'function'
                      || typeof mod.resolveQuoteStyle !== 'function') return;
                  const style = mod.resolveQuoteStyle(
                    (p && p.language) || 'de', (p && p.region) || 'CH');
                  mod.normalizeQuotes(content, style);
                  content.dispatchEvent(new InputEvent('input', { bubbles: true }));
                  try { await window.__standalone.save(); } catch (_) {}
                  try { window.__countStats && window.__countStats(); } catch (_) {}
                } catch (e) {
                  fb.log?.('Anführungszeichen: ' + (e && e.message ? e.message : e), 'info');
                }
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
                saveCaret(currentPageId);   // Position für späteres Wieder-Öffnen merken
                try { await window.__standalone.save(); } catch (_) {}
                currentPageId = null;
                currentBookId = null;
                try {
                  window.__standalone.setPage({ id: '', name: '', html: '<p><br></p>' });
                } catch (_) {}
                // Geschlossene Seite → kein Undo mehr, das in eine leere
                // Schreibfläche hineingreifen könnte.
                clearUndoSoon();
                resetTextLen();
                showEmpty();
                reportEditorState(null, false);
                try { window.__countStats && window.__countStats(); } catch (_) {}
              });

        """
}
