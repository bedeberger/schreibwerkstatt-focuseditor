# App-Review-Notes (Mac App Store)

Der englische Block unten geht **1:1** in App Store Connect → Version →
*App Review Information* → **Notes**. Er deckt die zwei Punkte ab, die beim
Review erfahrungsgemäss sonst zurückkommen:

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

**Felder in App Store Connect:** *Sign-in required* = **Yes** ankreuzen (die App
zeigt eine Login-Ansicht). In *User Name* / *Password* die Web-Zugangsdaten des
Demo-Kontos aus `scripts/demo.env` (`DEMO_EMAIL` / `DEMO_PASSWORD`) eintragen —
der Client selbst braucht sie nicht, der Demo-Knopf genügt; sie sind nur da,
falls der Reviewer die Web-Seite dazu anschaut. **Nie** ein persönliches Konto
und **nie** das Device-Token dort eintragen.

Bei Änderungen am Demo-Zugang oder am OTA-Bundle diese Notes mitpflegen
(s. [SIGNING.md](SIGNING.md) „App Store").

---

## Zum Kopieren (EN)

```text
Thank you for reviewing Focuseditor.

1) HOW TO SIGN IN — ONE CLICK, NO CREDENTIALS NEEDED

Focuseditor is a companion app for Schreibwerkstatt, a server-based writing
platform. It needs an account on a Schreibwerkstatt server, and the regular
sign-in uses a device token that the user copies from their server's web
profile. Because a reviewer cannot obtain such a token, we ship a built-in
demo access:

  Launch the app -> on the sign-in screen, click "Open demo".

That is all. No user name, no password, no token. The button signs you in to a
public test account on our demo server (demo.schreibwerkstatt.app) and takes
you straight to the editor. The demo content is shared between demo users and
is reset regularly, so please treat anything you write there as throwaway.

If you prefer to use the credentials we entered in the sign-in fields of this
submission, they belong to the same public demo account on the web interface at
https://demo.schreibwerkstatt.app — the macOS app itself does not need them.

What to try after signing in: pick a book and a page from the page picker
(Cmd-O), type into the page, and note that text is saved locally first and
synced to the server in the background. Cmd-, opens Settings; Cmd-? lists all
keyboard shortcuts.

2) ABOUT THE DOWNLOADED EDITOR BUNDLE (GUIDELINE 2.5.2)

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

3) PRIVACY / NETWORKING

The app talks to exactly one server: the Schreibwerkstatt instance the user
configures (the demo server, if you use the demo button). Documents are stored
locally in a SQLite mirror and synced to that server. There is no analytics,
no advertising, and no third-party SDK. Sign-in tokens are stored in the macOS
Keychain.

Happy to provide anything else you need — thank you!
```
