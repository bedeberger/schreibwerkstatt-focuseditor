# App-Review-Notes (Mac App Store)

Der englische Block unten geht **1:1** in App Store Connect → Version →
*App Review Information* → **Notes** und dient gleichzeitig als Antwort im
*Resolution Center*, wenn der Review nach Guideline 2.1 zusätzliche Angaben
verlangt (Stand: Ablehnung vom 2026-08-14, „Information Needed"). Er ist nach
den sieben Punkten gegliedert, die Apple in diesem Fall abfragt, und deckt
zusätzlich die zwei Punkte ab, die sonst erfahrungsgemäss zurückkommen:

1. **Login-Wand.** Der normale Login verlangt ein Device-Token per Copy-Paste —
   das kann ein Reviewer nicht beschaffen. Darum ist der Knopf „Demo öffnen"
   ([Auth/DemoAccess.swift](schreibwerkstatt-focuseditor/Auth/DemoAccess.swift))
   im Store-Build bewusst aktiv: ein Klick, kein Konto, kein Token.
2. **Guideline 2.5.2 (heruntergeladener Code).** Die App zieht das
   Editor-Bundle per OTA vom Server des Nutzers
   (`GET /content/editor-bundle.zip`). Das ist HTML/CSS/JS, das **ausschliesslich
   von WebKit interpretiert** wird — kein ausführbarer Code, kein Nachladen in
   den App-Prozess, keine Änderung am Funktionsumfang. Genau die Ausnahme, die
   2.5.2 für WebKit-interpretierten Code vorsieht.

**Notes-Feld nur von Hand:** der API-Key in `scripts/release.env` hat
„Developer"-Rechte — `GET` auf `/v1/apps` und `appStoreReviewDetail` geht,
`PATCH /v1/appStoreReviewDetails/<id>` antwortet **403 FORBIDDEN_ERROR** („The
API key in use does not allow this request"). Metadaten schreiben verlangt einen
Key mit **App Manager**-Rolle. Ohne solchen Key: Block unten im Browser
einfügen. Für Reviewer-Antworten im *Resolution Center* gibt es ohnehin keine
API — die Antwort inkl. Video-Anhang geht immer über die Weboberfläche.
Nützliche IDs: App `6797073919` („Schreibwerkstatt Focuseditor"), Version 3.18 =
`64fc2ae6-d94a-4588-a6f1-07d0a1984002`.

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

## Zum Kopieren (EN)

```text
Thank you for reviewing Focuseditor. Below is the information requested under
Guideline 2.1, in the order you asked for it.

--------------------------------------------------------------------------
1) SCREEN RECORDING
--------------------------------------------------------------------------

A screen recording captured on a physical Mac running the latest version of
macOS is attached to this message. It starts with launching the app and shows,
in this order: the sign-in screen, signing in with one click (see 4), the page
picker with search and chapter groups, opening a page, writing into it and
saving, the settings tabs (General, Typography, Writing, Sync, Account), and the
in-app account deletion flow — followed by signing in again to show that the
shared demo account is reset rather than destroyed.

Not shown, because the app does not contain them: there are no purchases,
subscriptions or paid content of any kind; no advertising; and no prompts for
sensitive data or device capabilities (the app requests no access to location,
contacts, camera, microphone, photos, or App Tracking Transparency). The app is
sandboxed and its only privileged capability is outgoing network access.

Regarding user-generated content: all content is the user's own writing inside
their own account on their own Schreibwerkstatt server. There is no public feed,
no discovery, no comments, no messaging and no anonymous interaction between
users — nothing is published to other users of the app. Content can only ever
become visible to a person the author explicitly invites as an editor for a
specific book on the server's web interface. Because there is no public or
anonymous user-to-user content, the app does not include reporting or blocking
mechanisms.

--------------------------------------------------------------------------
2) DEVICES AND OPERATING SYSTEMS TESTED
--------------------------------------------------------------------------

- MacBook Pro (16-inch, Apple silicon; model identifier Mac16,8), macOS 26.5.2
  — primary development and test machine, used for the attached recording.
- The minimum supported system is macOS 14.0; the app is built against the
  current macOS SDK and tested on the latest macOS release.

--------------------------------------------------------------------------
3) WHAT THE APP DOES, AND FOR WHOM
--------------------------------------------------------------------------

Focuseditor is a distraction-free writing app for macOS. It is the native
companion app for Schreibwerkstatt, a server-based platform for writing books
(chapters, pages, editorial review). The web platform shows a lot of context
around the text; this app deliberately shows only one thing: the page you are
writing, in a typographically calm, full-height writing surface, with optional
dimming of everything except the paragraph or sentence you are in.

Problem it solves: authors who write long-form text need two things the browser
does not give them — quiet (no tabs, no toolbars, no surrounding project UI) and
reliability without a connection (a browser tab loses text when the network or
the tab does). Focuseditor writes every keystroke into a local SQLite mirror
first and synchronises with the server in the background, so writing continues
uninterrupted on a train, on a plane or in a hotel with bad Wi-Fi, and picks up
again automatically when the connection returns.

Value it provides: focused writing, full offline capability, native macOS
behaviour (menus, keyboard shortcuts, light/dark mode, typography settings),
plus the writing-support features of the platform where a server is reachable
(spell checking, synonyms, typographic quotation marks, starting a server-side
editorial check for the open page, writing time and word-count goals).

Target audience: authors and other people writing long-form German or English
text who already use — or set up — a Schreibwerkstatt server. The app is not a
standalone editor: it requires an account on such a server, which is stated in
the App Store description, on the sign-in screen and in the app's About window.
There is no content aimed at children and no age-sensitive content; the app
contains only what its user writes.

--------------------------------------------------------------------------
4) SETUP AND ACCESS — ONE CLICK, NO CREDENTIALS NEEDED
--------------------------------------------------------------------------

The regular sign-in uses a device token that a user copies from their own
server's web profile. A reviewer cannot obtain such a token, so the app ships a
built-in demo access:

  Launch the app -> on the sign-in screen, click "Open demo".

That is all. No user name, no password, no token to type. The button signs you
in to a public test account on our demo server (https://demo.schreibwerkstatt.app)
and takes you straight to the editor, with sample books and pages already
present. The demo content is shared between demo users and is reset regularly,
so please treat anything you write there as throwaway.

The credentials entered in the sign-in fields of this submission belong to the
same public demo account on the web interface at https://demo.schreibwerkstatt.app
— the macOS app itself does not need them; they are provided only in case you
would like to look at the server side.

Main features and how to reach them after signing in:
- Cmd-O            open the page picker; choose a book and a page
- type / Cmd-S     write; text is stored locally first and synced in background
- Cmd-,            Settings (language, appearance, focus level, typography,
                   word-count goal, sync interval, spell check, account)
- Cmd-?            list of all keyboard shortcuts
- Cmd-Shift-S      synonym suggestions for the word at the cursor
- toolbar icons    typographic quotation marks; start a server-side editorial
                   check for the open page; page picker; statistics

Account deletion (Guideline 5.1.1(v)): Settings (Cmd-,) -> Account -> "Delete
account…", then type DELETE to confirm. Please note one detail so the result
does not look wrong to you: for the shared public demo account, the server
resets the account instead of destroying it (otherwise the demo access would be
gone for the next reviewer and for everyone else). The app behaves exactly as it
does for a real account — it deletes all local data for that server, signs out
and returns to the sign-in screen. For a normal user account the same flow
permanently deletes the account and all of its content on the server, with no
grace period. No sample file is needed anywhere in the app.

Offline behaviour, if you would like to verify it: after the first successful
sign-in, turn off networking and keep writing — the app stays fully functional;
when networking returns, changes are pushed automatically.

--------------------------------------------------------------------------
5) EXTERNAL SERVICES, TOOLS AND PLATFORMS
--------------------------------------------------------------------------

The app itself contacts exactly one host: the Schreibwerkstatt server the user
is signed in to (https://demo.schreibwerkstatt.app when the demo button is
used). It talks to no other network endpoint, and it contains no third-party
SDK for analytics, advertising, attribution or crash reporting.

- Authentication: our own Schreibwerkstatt server, using a device token
  (bearer token) stored in the macOS Keychain. No third-party identity
  provider, no social sign-in, no OAuth provider is involved in the app.
- Content storage and sync: the same Schreibwerkstatt server (a self-hosted
  Node.js/Express application with a SQLite database), plus a local SQLite
  mirror inside the app's container.
- Payment processors: none. The app contains no purchases, no subscriptions and
  no paid content, and it collects no payment data.
- Spell and grammar checking: LanguageTool (https://languagetool.org), reached
  through our server, never directly from the app. It is optional and off by
  default; on the demo server it is currently disabled, so it will not appear in
  your review.
- Synonyms (dictionary source): OpenThesaurus (https://www.openthesaurus.de), a
  free German community thesaurus, queried by our server, not by the app.
- AI services: the platform's optional AI-assisted features (AI synonym
  suggestions and the server-side editorial check for a page) run entirely on
  our server, which sends the relevant text to Anthropic's Claude API
  (https://www.anthropic.com, model claude-sonnet-4-6 on our demo and
  production servers). The app never contacts an AI provider itself; it only
  starts a job on our server and displays the resulting count. No AI-generated
  content is presented as factual information, and the user always triggers
  these features explicitly.
- Open-source components compiled into the app: GRDB (SQLite access layer).
  The Sparkle update framework used by our direct-download build is NOT part of
  the App Store build; updates for this version come from the App Store only.

Data collected: none beyond what is needed to provide the service — the user's
own documents and writing statistics, stored on the server they chose. No
tracking, no advertising identifiers, no data sharing with third parties.

--------------------------------------------------------------------------
6) REGIONAL DIFFERENCES
--------------------------------------------------------------------------

There are none. The app offers the same features and the same content in every
region, with no geographic restrictions, no region-specific pricing (it has no
purchases), and no region-gated functionality.

The only locale-dependent behaviour is language-related and follows the user's
own settings, not their location: the interface is available in German and
English (following the system language, overridable in Settings), and the
typographic quotation marks and spell-check language follow the language
configured for the book being written (for example Swiss German « », German
„ ", English " ").

--------------------------------------------------------------------------
7) REGULATED INDUSTRY / THIRD-PARTY MATERIAL
--------------------------------------------------------------------------

The app does not operate in a regulated industry. It is a text editor: no
health, financial, gambling, medical, legal, government or similar regulated
content or services, and no HealthKit, no payments, no cryptocurrency.

It also contains no protected third-party material. All content in the app is
written by the user. The demo content on our demo server is our own sample
text. The third-party services listed under (5) are used under their public
terms: LanguageTool and OpenThesaurus (free/open services, queried by our
server) and Anthropic's Claude API (used by us under our own commercial API
account). Both the app and the Schreibwerkstatt server platform are developed
by us; no licensed content, media library, catalogue or trademark of another
party is included.

--------------------------------------------------------------------------
ADDITIONAL NOTE: THE DOWNLOADED EDITOR BUNDLE (GUIDELINE 2.5.2)
--------------------------------------------------------------------------

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

Happy to provide anything else you need — thank you!
```
