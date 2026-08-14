# App-Review-Notes (Mac App Store)

Der englische Block unten geht **1:1** in App Store Connect → Version →
*App Review Information* → **Notes** und dient gleichzeitig als Antwort im
*Resolution Center*, wenn der Review nach Guideline 2.1 zusätzliche Angaben
verlangt (Stand: Ablehnung vom 2026-08-14, „Information Needed"). Er ist nach
den sieben Punkten gegliedert, die Apple in diesem Fall abfragt, und hält die
**4000-Zeichen-Grenze** des Feldes ein.

Zwei Dinge, die erfahrungsgemäss trotzdem zurückkommen:

1. **Login-Wand.** Der normale Login verlangt ein Device-Token per Copy-Paste —
   das kann ein Reviewer nicht beschaffen. Darum ist der Knopf „Demo öffnen"
   ([Auth/DemoAccess.swift](schreibwerkstatt-focuseditor/Auth/DemoAccess.swift))
   im Store-Build bewusst aktiv: ein Klick, kein Konto, kein Token. Steht im
   Block unter Punkt 4.
2. **Guideline 2.5.2 (heruntergeladener Code).** Die App zieht das
   Editor-Bundle per OTA vom Server des Nutzers
   (`GET /content/editor-bundle.zip`). Das ist HTML/CSS/JS, das **ausschliesslich
   von WebKit interpretiert** wird — kein ausführbarer Code, kein Nachladen in
   den App-Prozess, keine Änderung am Funktionsumfang. Genau die Ausnahme, die
   2.5.2 für WebKit-interpretierten Code vorsieht. Passt **nicht** mehr in die
   4000 Zeichen und liegt darum als eigener Baustein unten — nur nachschicken,
   wenn das Thema aufkommt.

**Notes-Feld nur von Hand:** der API-Key in `scripts/release.env` hat
„Developer"-Rechte — `GET` auf `/v1/apps` und `appStoreReviewDetail` geht,
`PATCH /v1/appStoreReviewDetails/<id>` antwortet **403 FORBIDDEN_ERROR** („The
API key in use does not allow this request"). Metadaten schreiben verlangt einen
Key mit **App Manager**-Rolle. Ohne solchen Key: Block unten im Browser
einfügen. Für Reviewer-Antworten im *Resolution Center* gibt es ohnehin keine
API — die Antwort inkl. Video-Anhang geht immer über die Weboberfläche.
**Build-Upload geht dagegen mit diesem Key** (nur Metadaten sind gesperrt):
`xcrun altool --upload-package … --apple-id 6797073919` lieferte 3.19 (41) am
2026-08-14 mit `UPLOAD SUCCEEDED` ab.
Nützliche IDs: App `6797073919` („Schreibwerkstatt Focuseditor"), abgelehnte
Version 3.18 = `64fc2ae6-d94a-4588-a6f1-07d0a1984002` (Versionsnummer dort auf
3.19 setzen, damit Build 41 zuordenbar ist).

**Felder in App Store Connect:** *Sign-in required* = **Yes** ankreuzen (die App
zeigt eine Login-Ansicht). In *User Name* / *Password* die Web-Zugangsdaten des
Demo-Kontos aus `scripts/demo.env` (`DEMO_EMAIL` / `DEMO_PASSWORD`) eintragen —
der Client selbst braucht sie nicht, der Demo-Knopf genügt; sie sind nur da,
falls der Reviewer die Web-Seite dazu anschaut. **Nie** ein persönliches Konto
und **nie** das Device-Token dort eintragen. Stand 2026-08-14 steht in der
Einreichung `demoAccountRequired = false`, also **ohne** Zugangsdaten — mit dem
Ein-Klick-Demo-Knopf vertretbar, aber Apple fragt danach; darum umstellen.

Bei Änderungen am Demo-Zugang oder am OTA-Bundle diese Notes mitpflegen
(s. [SIGNING.md](SIGNING.md) „App Store").

## Vor dem Absenden prüfen

- **Geräteliste (Punkt 2 unten) aktualisieren** — Apple will die real
  getesteten Macs + macOS-Versionen. Modellname:
  `sysctl -n hw.model`, Version: `sw_vers`.
- **Demo-Instanz erreichbar?**
  `set -a; . scripts/demo.env; set +a; curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $DEMO_DEVICE_TOKEN" "$DEMO_BASE_URL/me/device-tokens"`
  → `200`. Ohne erreichbaren Demo-Server scheitert der Review sofort.
- **Screencast beigelegt?** Apple verlangt bei 2.1 ein Video. Frisch aufnehmen
  mit `scripts/appstore-review-video.sh` (Abschnitt unten) — bei einer macOS-App
  ist „physical device" ein echter Mac mit aktuellem macOS, kein Simulator.
  Achtung: der Lauf **setzt das Demo-Konto zurück** (Kontolöschung ist Teil des
  Ablaufs).

## Screencast (Punkt 1) — automatisiert

[scripts/appstore-review-video.sh](scripts/appstore-review-video.sh) nimmt das
Video komplett selbst auf: es baut eine isolierte Kopie des **MAS-Targets**
(eigene Bundle-ID + eigener Keychain-Service, damit der Demo-Login nicht das
Produktions-Gerätetoken überschreibt — und damit im Konto-Reiter **kein**
Sparkle-„Check for Updates…" zu sehen ist, das der Store-Build nicht hat),
stellt den abgemeldeten Ausgangszustand her und fährt den Ablauf per CGEvent +
AppleScript ab. Ergebnis: `AppStore/review-video/focuseditor-review-<datum>.mov`
(1920×1200, ~140 s, ~8 MB; der Ordner ist gitignoriert). Zuletzt aufgenommen
**2026-08-14** auf MacBook Pro 16″ (Mac16,8), macOS 26.5.2.

Der aufgenommene Ablauf — deckt Apples Pflichtpunkte ab:

1. App-Start bis zur **Login-Ansicht** (kein Token in der Keychain).
2. **„Open demo"** → Editor-Bundle wird geladen, Editor öffnet sich.
3. **Seiten-Picker** (⌘O) mit Suche, „Recently opened" und Kapitelgruppen,
   Auswahl per Tastatur → Seite öffnen.
4. **Schreiben**: Caret ans Textende (⌘↓), drei Sätze tippen, Zeichenzähler in
   der Toolbar wächst, ⌘S sichern.
5. **Einstellungen** (⌘,): General → Typography → Writing → Sync → Account.
6. **Kontolöschung**: Account → „Delete account…" → `DELETE` tippen →
   „Delete account permanently" → Bestätigungsdialog → App ist abgemeldet.
7. **Erneut „Open demo"** — zeigt, dass das Demo-Konto serverseitig nur
   **zurückgesetzt** wurde (siehe EN-Block, Punkt 4).

**Bewusst nicht im Video** (weil die App es nicht hat): Käufe/Abos,
Berechtigungsdialoge (Kamera/Ort/Kontakte/ATT), öffentlicher Feed. Der EN-Block
sagt das ausdrücklich. **Ebenfalls nicht drin:** der Offline-Beweis (WLAN aus →
weiterschreiben → WLAN an) — das Skript schaltet bewusst kein Netz ab. Wer ihn
zeigen will, macht diesen Teil von Hand; der EN-Block behauptet ihn nicht.

**Wenn Koordinaten nicht mehr passen** (UI verschoben, andere Sprache): Fenster
auf 1440×900 an (60,60) setzen, `screencapture -x -R 60,60,1440,900` machen, Bild
ansehen, Bildpixel ÷ 2 + Fensterursprung = Klickpunkt. Details im Skriptkopf.

---

## Zum Kopieren (EN) — 3942 Zeichen, Limit 4000

**Das Feld nimmt maximal 4000 Zeichen** (Notes *und* Antwort im Resolution
Center). Der Block unten liegt bei 3942 — beim Ergänzen mitzählen:

```bash
pbpaste | wc -m
```

```text
Answers to all seven points:

1) RECORDING: attached; captured on the Mac listed in (2). It shows app launch, one-click demo sign-in, the page picker, opening a page, writing, saving, settings and in-app account deletion, then signing in again (the demo account is reset, not destroyed). The app has no purchases, subscriptions or advertising, and requests no sensitive data or capabilities (no location, contacts, camera, microphone, photos, ATT). All content is the user's own writing in their own account: no public feed, comments or messaging, hence no reporting or blocking mechanism; text reaches others only if the author invites an editor on the web interface.

2) TESTED ON: MacBook Pro 16" (Apple silicon, Mac16,8), macOS 26.5.2. Minimum supported: macOS 14.0.

3) FUNCTION/AUDIENCE: a distraction-free writing app, native companion to Schreibwerkstatt, a server-based book-writing platform. It shows only the page being written, dimming all but the current sentence. Every keystroke goes into a local SQLite mirror first and syncs in the background, so writing works offline and catches up by itself — unlike a browser tab. Server-side aids when online: spell check, synonyms, typographic quotes, editorial check. Audience: authors of long-form German or English text who use a Schreibwerkstatt server. Not standalone: such an account is required, as stated in the description, sign-in screen and About window. Nothing targets children.

4) ACCESS, ONE CLICK, NO CREDENTIALS: sign-in normally needs a device token from the user's own server profile, which a reviewer cannot obtain, so the app ships demo access: launch it, click "Open demo" — no name, password or token. It opens a public test account on demo.schreibwerkstatt.app with sample books; that content is shared and reset regularly, so treat it as throwaway. The credentials in the sign-in fields are for the same account on the web interface only. Keys: Cmd-O picker, Cmd-S save, Cmd-, settings, Cmd-? shortcuts, Cmd-Shift-S synonyms. Account deletion (5.1.1(v)): Cmd-, then Account, "Delete account…", type DELETE. Note: for the shared demo account the server resets it instead of deleting it, otherwise demo access would be gone for everyone; the app behaves identically (local data removed, signed out, back to sign-in). For a real account it deletes the account and all content permanently, with no grace period. No sample files needed.

5) EXTERNAL SERVICES: the app talks to exactly one host, the Schreibwerkstatt server the user signs in to, and has no third-party SDK for analytics, ads or crash reporting. Auth, storage and sync: our own server (Node.js/Express, SQLite) plus a local SQLite mirror; bearer device token in the macOS keychain; no third-party identity provider. Payments: none. Spell/grammar check: LanguageTool via our server (optional, currently off on the demo server). Synonyms: OpenThesaurus via our server. Optional AI features (synonym suggestions, editorial check) run on our server via Anthropic's Claude API; the app never contacts an AI provider, and the user triggers them explicitly. Bundled open source: GRDB (SQLite). The Sparkle updater of our direct-download build is NOT in the App Store build. No tracking or data sharing.

6) REGIONS: no differences, no geographic restrictions or region-gated features. Locale behaviour follows user settings, not location: interface in German and English; quotation marks and spell-check language follow the book's language.

7) REGULATED INDUSTRY, THIRD-PARTY MATERIAL: neither. A text editor: no health, finance, gambling, medical, legal or government content, no HealthKit, payments or crypto. All content is written by the user; the demo text is ours. The services above are used under their public terms, Anthropic under our commercial API account. App and server platform are ours; no licensed third-party content or trademarks are included.

Happy to answer anything else — thank you.
```

## Zusatzbaustein: OTA-Editor-Bundle (Guideline 2.5.2)

Bewusst **nicht** im 4000-Zeichen-Block: Apple hat danach nicht gefragt, und der
Platz fehlt. Kommt das heruntergeladene Editor-Bundle im Review zur Sprache
(„downloaded code"), diesen Text als eigene Nachricht nachschicken:

```text
On first launch (and on later launches as a conditional, ETag-based refresh),
the app downloads a small "editor bundle" from the Schreibwerkstatt server the
user is signed in to, and caches it in the app's Application Support folder.
We want to be transparent about what that is, because it may look like
downloaded code:

- The bundle contains only HTML, CSS and JavaScript. There is no executable
  code, no native code, no frameworks, dylibs, plug-ins or bytecode of any kind.
- Its contents are only ever interpreted by WebKit, inside the app's WKWebView.
  Nothing from the bundle is loaded into the app process, and no code is
  compiled, installed or executed outside of WebKit.
- The bundle does not introduce or change features or functionality. The app is
  and remains exactly what it says it is: a distraction-free editor for a single
  page of text. The bundle carries the text-editing surface itself — the
  editor's markup handling, layout and stylesheet — so that it always matches
  the document format of the server the user writes against. It cannot add
  screens, menus, purchases or any other capability; all app features, windows,
  menus, settings and network access are implemented natively in the app.
- The web view never loads a remote URL. It only reads from the local cache via
  a custom scheme. All network traffic (sign-in, sync, and the bundle download
  itself) is done by the native layer over HTTPS.
- After the first successful download the app works fully offline from the
  cached bundle.

This is the case that Guideline 2.5.2 explicitly permits: scripts and code
downloaded and run by Apple's built-in WebKit framework, which do not change
the app's primary purpose and provide no store-like interface.
```
