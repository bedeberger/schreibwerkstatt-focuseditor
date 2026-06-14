# Mutterrepo-Prompt: LanguageTool im macOS-Focus-Editor freischalten

Dieser Prompt ist für eine Claude-Code-Session **im Hauptrepo**
(`/Users/bd/ClaudeProjects/schreibwerkstatt`). Er macht die bestehende
LanguageTool-Rechtschreibprüfung im nativen macOS-Client (schreibwerkstatt-
focuseditor) nutzbar — **ohne neuen Server-Endpoint** (die API existiert
bereits) und **ohne Editor-Fork** (SSoT bleibt `public/js`).

Zwei kleine Änderungen, die **zusammen** deployt werden müssen:

1. `public/js/cards/editor-spellcheck/controller.js` — den Netzwerk-Transport
   injizierbar machen (Default bleibt `fetch`, Web-App unverändert).
2. `lib/editor-bundle.js` — Spellcheck-Controller + CSS + `icons.svg` ins
   OTA-Bundle aufnehmen, das der macOS-Client zieht.

Hintergrund: Der Mac-Client lädt das Editor-Bundle **offline** in eine WKWebView
und darf **keinen direkten `fetch`** machen — Netzwerk läuft ausschließlich über
eine Swift-Bridge. Damit der unveränderte `controller.js` wiederverwendbar ist,
müssen seine zwei `fetch`-Aufrufe hinter injizierbare Callbacks. Im Browser
bleibt alles beim Alten; nur die Mac-Schale reicht bridge-gestützte Transports
rein.

---

## Änderung 1 — `public/js/cards/editor-spellcheck/controller.js`

### 1a. Toten Import entfernen

`escHtml` wird nirgends aufgerufen (nur `void escHtml;` am Dateiende). Der
Import zieht sonst `utils.js` (~38 KB) unnötig ins Mac-OTA-Bundle.

- Zeile entfernen: `import { escHtml } from '../../utils.js';`
- Am Dateiende den Block entfernen (XSS-Hinweis-Kommentar + `void escHtml;`).
  (`buildOffsetTable, rangeFromOffset` aus `./mapping.js` **bleiben**.)

### 1b. Zwei injizierbare Transport-Callbacks ergänzen

In der Options-Destrukturierung von `createSpellcheckController({...})` zwei
optionale Parameter mit **fetch-Defaults** ergänzen (Default = heutiges
Verhalten inkl. 404→disabled):

```js
  checkText = async ({ text, language, bookId, pageId, signal }) => {
    const resp = await fetch('/languagetool/check', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ text, language, bookId, pageId }),
      signal,
      credentials: 'same-origin',
    });
    if (resp.status === 404) return { disabled: true };
    if (!resp.ok) throw new Error('lt_http_' + resp.status);
    const json = await resp.json();
    return { matches: Array.isArray(json.matches) ? json.matches : [] };
  },
  addWord = async ({ word, bookId, lang }) => {
    const resp = await fetch('/dictionary', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ word, bookId, lang }),
      credentials: 'same-origin',
    });
    return resp.ok;
  },
```

### 1c. `_runCheck` auf `checkText` umstellen

Den Inline-`fetch`-Block in `_runCheck` (der `try { const resp = await
fetch('/languagetool/check', …) … } catch (err) { … }`) ersetzen durch einen
Aufruf des Callbacks. Die übrige Logik (seq/stale-Check, `lastHtmlSnapshot`-
Drift-Check, `_renderMatches`, Badge) bleibt identisch:

```js
    let result;
    try {
      result = await checkText({
        text: table.text, language, bookId, pageId, signal: abortCtrl.signal,
      });
    } catch (err) {
      if (err && err.name !== 'AbortError') _updateBadge('error');
      return;
    }
    if (myReq !== seq) return; // stale
    if (result && result.disabled) { _renderMatches([]); _updateBadge('disabled'); return; }
    const currentSnap = getHtml ? getHtml() : root.innerHTML;
    if (currentSnap !== lastHtmlSnapshot) return; // DOM mutated mid-flight
    const matches = (result && Array.isArray(result.matches)) ? result.matches : [];
    _renderMatches(matches, table);
    lastCheckedText = table.text;
    const visibleCount = matches.filter((m) => !ignored.has(_matchId(m))).length;
    _updateBadge(visibleCount ? 'matches' : 'clean', { count: visibleCount });
```

### 1d. „Zum Wörterbuch"-Button auf `addWord` umstellen

Im Klick-Handler des `dictBtn` (im `_openPopover`) den Inline-`fetch('/dictionary',
…)` ersetzen durch:

```js
        dictBtn.addEventListener('click', async () => {
          dictBtn.disabled = true;
          try {
            const rawLang = getBookLocale ? getBookLocale() : '*';
            const lang = (!rawLang || rawLang === 'auto') ? '*' : rawLang;
            const ok = await addWord({ word, bookId: 0, lang });
            if (ok) {
              const entry3 = squiggles.get(matchId);
              if (entry3) {
                highlights[entry3.category]?.delete(entry3.range);
                squiggles.delete(matchId);
              }
              _closePopover();
              _scheduleCheck({ force: true });
            } else {
              dictBtn.disabled = false;
            }
          } catch { dictBtn.disabled = false; }
        });
```

**Web-App-Regressionstest:** `dispatch.js` ruft `createSpellcheckController`
**ohne** `checkText`/`addWord` → Defaults greifen → identisches Verhalten.
Bestehende e2e-Tests (`spellcheck-focus/notebook/book.spec.js`) müssen grün
bleiben.

---

## Änderung 2 — `lib/editor-bundle.js` (OTA-Bundle für den Mac-Client)

Der macOS-Client zieht `GET /content/editor-bundle.zip`; dieses Modul baut das
ZIP. Drei Ergänzungen:

1. **Spellcheck-Controller als Entry** (die Closure zieht `mapping.js`
   automatisch; nach Änderung 1a **kein** `utils.js` mehr):

   ```js
   const ENTRY_MODULES = [
     'js/editor/focus.js',
     'js/editor/focus/standalone.js',
     'js/editor/shared/editor-host.js',
     'js/editor/shared/block-merge.js',
     'js/cards/editor-spellcheck/controller.js',   // ← neu (Mac-Spellcheck)
   ];
   ```

2. **Spellcheck-CSS** (treibt `::highlight(lt-*)`-Underlines, Badge, Popover —
   ans Ende von `CSS_FILES`):

   ```js
     'css/editor/spellcheck.css',                  // ← neu
   ```

3. **`icons.svg` als Roh-Asset** ins ZIP-Root (der Badge referenziert
   `/icons.svg#check|alert-triangle|loader|x`). Die Closure deckt nur JS+CSS ab,
   daher explizit ergänzen — z. B. eine `EXTRA_ASSETS`-Liste:

   ```js
   const EXTRA_ASSETS = ['icons.svg'];
   ```

   …und in `_build()` vor `zip.generateAsync` mit einpacken (Pfad bleibt
   `icons.svg`, also Bundle-Root):

   ```js
   for (const rel of EXTRA_ASSETS) {
     if (existsSync(join(PUBLIC_DIR, rel))) {
       zip.file(rel, await readFile(join(PUBLIC_DIR, rel)));
     } else {
       logger.warn(`editor-bundle: Asset fehlt: ${rel}`);
     }
   }
   ```

   (Optional `icons.svg` auch in den ETag-Hash aufnehmen, damit der Client bei
   Icon-Änderungen neu zieht — analog zu den anderen Dateien.)

Nach dem Deploy (systemd-Restart) ist `_cache` frisch; der Client zieht das neue
Bundle beim nächsten Online-Start (ETag ändert sich).

---

## Was der Mac-Client bereits erledigt (kein Handlungsbedarf im Hauptrepo)

- Bridge-Ops `spellcheckConfig` / `languagetoolCheck` / `dictionaryAdd` → proxyen
  `GET /config`, `POST /languagetool/check`, `POST /dictionary` mit Device-Token.
- Boot-Script verdrahtet `createSpellcheckController` mit bridge-gestützten
  `checkText`/`addWord` und reicht `bookId`/`pageId` der offenen Seite mit.
- **Locale:** Der Client sendet `language: 'auto'` + `bookId`. Server-seitig
  gewinnt `getBookLocale(bookId)` (→ `de-CH`) über `body.language` — die
  Buch-Sprache wird also korrekt aufgelöst, ohne dass der Client sie kennt.
  `getBookLocale`/`getBookSettings` funktionieren ohne `userEmail`; der Device-
  Token-User liegt ohnehin auf `req.session.user` (Auth-Guard), also greift auch
  der Wörterbuch-Filter.

## Verifikation nach dem Deploy

1. `node -e "require('./lib/editor-bundle')._resetCache(); require('./lib/editor-bundle').getBundle().then(b=>console.log(b.manifest))"`
   → `jsFiles` enthält `js/cards/editor-spellcheck/controller.js` + `…/mapping.js`,
   `cssFiles` enthält `css/editor/spellcheck.css`.
2. `languagetool.enabled` + `languagetool.url` in `app_settings` gesetzt.
3. Mac-Client neu starten → tippt man einen Fehler, erscheint nach `debounce_ms`
   die Unterstreichung; Klick → Popover mit Vorschlägen + „Zum Wörterbuch".
