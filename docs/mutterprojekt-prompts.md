# Mutterprojekt-Prompts (Schreibwerkstatt-Hauptrepo)

Diese Prompts sind für eine Claude-Code-Session im **Hauptrepo**
`/Users/bd/ClaudeProjects/schreibwerkstatt` gedacht (SSoT des Focus-Editors).
Sie ermöglichen drei Einstellungen im macOS-Client (`schreibwerkstatt-focuseditor`),
die heute serverseitig/Editor-seitig nicht steuerbar sind.

**Gemeinsamer Kontext für alle Prompts:** Der macOS-Client lädt den Focus-Editor
nicht gebündelt, sondern zieht ihn per OTA-ZIP (`GET /content/editor-bundle.zip`,
`lib/editor-bundle.js`) und cacht ihn lokal. Editor-/CSS-Änderungen gehören
darum **ins Hauptrepo** — der Client zieht das aktualisierte Bundle beim nächsten
Start automatisch (ETag-getrieben). Harte Regel: **Default-Verhalten unverändert
lassen** (Backward-Compat), damit Web-App und bestehende Clients gleich aussehen;
neue Konfigurierbarkeit ist additiv mit Default = heutiger Wert.

Stand der Recherche: 2026-06-14. Zeilennummern können leicht abweichen — jeweils
am Symbol orientieren.

---

## Prompt 1 — LanguageTool: Picky-Modus pro Request übersteuerbar

**Aufgabe:** Im LanguageTool-Proxy `POST /languagetool/check`
(`routes/languagetool.js`) ein **optionales** `picky:boolean` aus dem
Request-Body akzeptieren, das den serverseitigen Default
`appSettings.get('languagetool.picky')` **nur für diesen Request** übersteuert.

**Heutiger Stand (verifiziert):**
- `routes/languagetool.js` ~Z. 32–44: Body-Parsing (`text`, `language`, `bookId`, `pageId`).
- ~Z. 61: `const picky = appSettings.get('languagetool.picky') === true;`
- ~Z. 78–91: Cache-Key enthält bereits `{ pageId, contentHash, lang, picky }`.
- ~Z. 142–147: `async function _callLT(url, text, language, picky, signal)` setzt
  `if (picky) params.set('level', 'picky')`.

**Umsetzung:**
1. Body-Feld `picky` einlesen: `const bodyPicky = typeof body.picky === 'boolean' ? body.picky : null;`
2. Effektiven Wert bilden: `const picky = bodyPicky !== null ? bodyPicky : (appSettings.get('languagetool.picky') === true);`
   (Default = heutiges Verhalten, wenn der Client nichts schickt.)
3. Der Cache-Key enthält `picky` bereits — sicherstellen, dass er den *effektiven*
   Wert nutzt (nicht den globalen), sonst kollidieren Picky-an/aus im Cache.
4. Keine weiteren Stellen; `_callLT` bekommt `picky` schon durchgereicht.

**Akzeptanzkriterien:**
- Ohne `picky` im Body: identisches Verhalten wie heute.
- `picky:true`/`false` im Body übersteuert pro Request; Cache trennt beide Varianten.
- Keine Änderung an `enabled`/`url`/`rules` (bleiben serverseitig).

**Client-Gegenstück (danach im macOS-Client):** `LTCheckRequest` + Bridge-Op
`languagetoolCheck` um `picky` erweitern; `SpellcheckPrefs` um einen
Tri-State-Override (auto/an/aus) + Settings-Picker im „Rechtschreibung"-Tab.

---

## Prompt 2 — Typewriter-Scroll: Anker-Position konfigurierbar

**Aufgabe:** Die vertikale Anker-Position des Typewriter-Scrollings (heute fix die
Viewport-**Mitte**) konfigurierbar machen (z. B. Mitte vs. oberes Drittel), ohne
das Default-Verhalten zu ändern.

**Heutiger Stand (verifiziert):**
- `public/js/editor/focus/typewriter.js` ~Z. 67–73:
  ```js
  export function computeTypewriterDelta(containerRect, targetRect, threshold = TYPEWRITER_THRESHOLD_PX) {
    const targetCenter = targetRect.top + targetRect.height / 2;
    const containerCenter = containerRect.top + containerRect.height / 2; // fix: Mitte
    const delta = targetCenter - containerCenter;
    return Math.abs(delta) < threshold ? 0 : delta;
  }
  ```
- ~Z. 75–91: `typewriterScroll(container, targetRect, ctx, threshold)` ruft `computeTypewriterDelta`.
- Aufrufer in `public/js/editor/focus/card.js` (~Z. 25–26) reicht die dynamische
  Schwelle durch.
- Anker ist NICHT konfigurierbar; `TYPEWRITER_THRESHOLD_PX = 16` in `constants.js`.

**Umsetzung:**
1. `computeTypewriterDelta(... , anchorRatio = 0.5)` ergänzen; `containerCenter`
   ersetzen durch `containerRect.top + containerRect.height * anchorRatio`
   (0.5 = heutige Mitte → Default unverändert; 0.33 = oberes Drittel).
2. `typewriterScroll(... , anchorRatio = 0.5)` durchreichen.
3. Den `anchorRatio` aus einem Host-/Config-Feld lesen — z. B. `host.typewriterAnchor`
   (Zahl 0–1) bzw. einem Wert, den `mountStandaloneFocus` entgegennimmt und auf den
   Host legt. Im `card.js`-Aufruf den Wert in `typewriterScroll(...)` einspeisen.
   Fallback 0.5, wenn nicht gesetzt.

**Akzeptanzkriterien:**
- Ohne gesetzten Anker: pixelidentisch zum heutigen Verhalten.
- `typewriterAnchor = 0.33` zentriert die Cursor-Zeile aufs obere Drittel.
- Funktioniert in `focus-mode--typewriter-only` UND in den Dim-Modi (Typewriter
  läuft laut `focus-mode.css` ~Z. 235 immer außer im Nicht-Typewriter-Fall).

**Client-Gegenstück:** Boot-Pull eines `typewriterAnchor`-Werts über die Bridge
(analog `focusGranularity`), an `mountStandaloneFocus`/Host übergeben; Settings-
Picker (Mitte / Oberes Drittel) im „Typografie"- oder „Fokus"-Bereich.

---

## Prompt 3 — Fokus-Dimm-Stärke über CSS-Variable steuerbar

**Aufgabe:** Die Abdunklung der nicht-aktiven Absätze im Fokus-Modus über eine
**fokus-eigene** CSS-Custom-Property steuerbar machen, ohne das globale Token
`--opacity-faint` (wird auch anderswo genutzt) zu verbiegen und ohne den heutigen
Default zu ändern.

**Heutiger Stand (verifiziert):**
- `public/css/editor/focus/focus-mode.css` ~Z. 235–241:
  ```css
  .focus-editor.is-active:not(.focus-mode--typewriter-only) .focus-editor__content
    :is(p,h1,h2,h3,h4,h5,h6,blockquote,li,pre):not(.focus-paragraph-active):not(.focus-paragraph-near) {
    opacity: var(--opacity-faint);   /* ≈ 0.35 */
  }
  ```
- ~Z. 251–253: `.focus-paragraph-near { opacity: 0.7; }` (Window-3-Nachbarn, hartkodiert).
- ~Z. 262–267: Sentence-Dim via `::highlight(focus-sentence-dim)` mit hartkodiertem
  `rgba(...)` — separat, optional.
- `focus-mode.css` ist bereits in `lib/editor-bundle.js` `CSS_FILES` gelistet →
  Änderungen kommen automatisch ins OTA-Bundle.

**Umsetzung:**
1. Fokus-scoped Variablen mit Default = heutigem Wert einführen, z. B. am
   `.focus-editor`-Wurzelselektor:
   ```css
   .focus-editor {
     --focus-dim-opacity: var(--opacity-faint);
     --focus-near-opacity: 0.7;
   }
   ```
2. In den beiden Regeln `var(--opacity-faint)` → `var(--focus-dim-opacity)` und
   `0.7` → `var(--focus-near-opacity)` ersetzen.
3. (Optional, falls gewünscht) Sentence-Dim ebenfalls auf eine Variable heben.

**Akzeptanzkriterien:**
- Ohne Override: visuell identisch (Defaults = heutige Werte).
- Setzt der Client `--focus-dim-opacity` (z. B. auf `:root`/`.focus-editor`),
  ändert sich nur die Fokus-Abdunklung — `--opacity-faint` bleibt unberührt.

**Client-Gegenstück:** Der Client hat bereits eine Override-Schicht
(`<style id="sw-native-typography">` + `:root`-Custom-Properties, siehe
`WebAssets.indexHTML`). Er setzt dann einfach `--focus-dim-opacity` dort; ein
Slider „Fokus-Abdunklung" im „Typografie"-Tab treibt den Wert.

---

## Nicht nötig: Auto-Save-Verzögerung (bereits unterstützt)

`mountStandaloneFocus({ mount, bridge, autosaveMs = DEFAULT_AUTOSAVE_MS })`
(`public/js/editor/focus/standalone.js` ~Z. 23, 97–109; Default `1500` ms) nimmt
die Debounce-Zeit **schon heute** als Parameter. Die Auto-Save-Verzögerung ist
darum **rein client-seitig** umsetzbar (Wert per Settings → an `mountStandaloneFocus`
übergeben) — **kein Mutterprojekt-Prompt erforderlich.**
