# Signieren, Notarisieren & Verteilen

Zwei Kanäle, ein Quellcode: **DMG** (Direktdownload, dieses Dokument bis zum
Abschnitt „Auto-Update") und **App Store** (Abschnitt „App Store" ganz unten).

Ziel des DMG-Wegs: Die App läuft auf fremden Macs ohne Gatekeeper-Warnung. Dafür
braucht es ein **Developer-ID-Zertifikat** + **Notarisierung** durch Apple.

## Schon vorbereitet (im Repo / Projekt)

- ✅ **App Sandbox** aktiv (`ENABLE_APP_SANDBOX = YES`).
- ✅ **Netzwerk-Client-Entitlement** über `ENABLE_OUTGOING_NETWORK_CONNECTIONS = YES`
  (Xcode erzeugt die Entitlements aus den Build-Settings — keine separate
  `.entitlements`-Datei nötig). Deckt Sync, OTA-Bundle und LanguageTool ab.
- ✅ **Hardened Runtime** aktiv (`ENABLE_HARDENED_RUNTIME = YES`) — Pflicht für die
  Notarisierung.
- ✅ **Apple Developer Program** (bezahlt) + **Developer-ID-Application**-Zertifikat
  im Keychain (Team `TQA2JLKT87`).
- ✅ **Notarisierung via App-Store-Connect-API-Key** (file-basiert) — keine
  Keychain-/Session-Abhängigkeit, läuft auch aus Hintergrund-/CI-Prozessen.
- ✅ Skripte: [scripts/release-dmg.sh](scripts/release-dmg.sh) (verteilbares DMG),
  [scripts/notarize.sh](scripts/notarize.sh) (App-only),
  [scripts/lib-notary.sh](scripts/lib-notary.sh) (Notarisierungs-Helfer, robustes
  Status-Polling statt `--wait`).

## Zugang (einmalig, lokal — NICHT im Git)

Alle Zugangsdaten stehen in **`scripts/release.env`** (in `.gitignore`; Vorlage:
[scripts/release.env.example](scripts/release.env.example)). Die Skripte sourcen
diese Datei automatisch. Inhalt:

```bash
DEV_ID_APP="<SHA-1 der Developer-ID-Identität>"   # security find-identity -v -p codesigning
NOTARY_KEY="$HOME/.appstoreconnect/AuthKey_XXXXXXXXXX.p8"
NOTARY_KEY_ID="XXXXXXXXXX"                          # steht im Dateinamen
NOTARY_ISSUER="xxxxxxxx-…-xxxxxxxxxxxx"             # Issuer-UUID
```

Die **`.p8`** liegt außerhalb des Repos (`~/.appstoreconnect/`, `chmod 600`) und
ist zusätzlich per `*.p8` in `.gitignore` geschützt.

**Falls das neu aufgesetzt werden muss** (anderer Mac / neuer Key):
1. Zertifikat: Xcode → Settings → Accounts → **Manage Certificates** → **+** →
   **Developer ID Application**. Hash holen mit `security find-identity -v -p codesigning`.
2. API-Key: appstoreconnect.apple.com → Users and Access → Integrations →
   **App Store Connect API** → Key (Access: Developer) generieren → `.p8` nach
   `~/.appstoreconnect/` laden → Key-ID + Issuer-ID notieren.
3. `cp scripts/release.env.example scripts/release.env` und Werte eintragen.

### Demo-Instanz (Smoke-Test + Demo-Login)

Zugang zur öffentlichen Demo-Instanz `demo.schreibwerkstatt.app` steht in
**`scripts/demo.env`** (ebenfalls in `.gitignore`; Vorlage:
[scripts/demo.env.example](scripts/demo.env.example)): `DEMO_BASE_URL`,
`DEMO_EMAIL`, `DEMO_PASSWORD`, `DEMO_DEVICE_TOKEN` (Bearer `swd_…`, Scopes
`content:read,content:write`).

Zweck: das notarisierte `.dmg` vor der Veröffentlichung gegen einen echten
Server durchprobieren (Server-URL in Settings → Allgemein auf `DEMO_BASE_URL`,
Login per `DEMO_DEVICE_TOKEN`), Screenshots/Doku, und als weitergebbarer
Demo-Login. Inhalte sind wegwerfbar, keine Produktivdaten.

```bash
set -a; . scripts/demo.env; set +a
# Token prüfen (200 = gültig):
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer $DEMO_DEVICE_TOKEN" "$DEMO_BASE_URL/me/device-tokens"
```

Das Klartext-Token gehört **nie** in getrackte Dateien — insbesondere nicht in
`schreibwerkstatt-focuseditor.xcodeproj/xcshareddata/xcschemes/…` (`SW_E2E_TOKEN`);
dieses Repo ist public.

#### Demo-Knopf im Login (ins Binary gebacken)

Der Login zeigt unter dem Anmelde-Knopf **„Demo öffnen"**, wenn ein Demo-Zugang
einkompiliert ist — damit Interessierte die App ohne eigenes Konto und ohne
Token-Copy-Paste ansehen können. Die Kette:

```
Config/Demo.xcconfig  (gitignored, Werte aus scripts/demo.env)
  -> Build-Settings SW_DEMO_HOST / SW_DEMO_TOKEN   (Version.xcconfig: #include?)
  -> Config/Info.plist  SWDemoHost / SWDemoDeviceToken   ($(…)-Expansion)
  -> Auth/DemoAccess.swift  -> Knopf in Auth/LoginView.swift
```

Setup auf einem neuen Mac: `cp Config/Demo.xcconfig.example Config/Demo.xcconfig`
und die Werte aus `scripts/demo.env` eintragen (Host **ohne** `https://` — in
xcconfig beginnt `//` einen Kommentar). **Fehlt die Datei, ist der Knopf einfach
aus und der Build läuft unverändert** — verifiziert am 2026-07-31 (Build grün,
`SWDemoHost` leer). Vor dem Release also prüfen, ob der Knopf im `.dmg`
tatsächlich erwünscht/vorhanden ist:

```bash
/usr/libexec/PlistBuddy -c "Print :SWDemoHost" \
  build/Build/Products/Release/Focuseditor.app/Contents/Info.plist
```

**Bewusste Abweichung von „Token nur im Keychain":** ein Token im Binary ist per
`strings` auslesbar. Deshalb darf dort ausschliesslich das Wegwerf-Demo-Konto
stehen (Scopes `content:read,content:write`, wegwerfbare Inhalte) — wird es
missbraucht, im Web-`/me`-Bereich widerrufen, neu ausstellen, `scripts/demo.env`
+ `Config/Demo.xcconfig` aktualisieren, neues Release. Nach dem Klick läuft der
Demo-Login wie jeder andere (Validierung + Keychain).

## Build + Notarisieren (jedes Release)

**Verteilung als `.dmg` (Standard):** ein Skript erledigt alles — Release bauen,
App signieren/notarisieren/stapeln, Drag-to-Applications-`.dmg` bauen, `.dmg`
signieren/notarisieren/stapeln, Gatekeeper-Check.

```bash
export DEV_ID_APP="Developer ID Application: David Berger (<TEAM_ID>)"
VERSION=1.0.0 scripts/release-dmg.sh
# Ergebnis: build/Build/Products/Release/Focuseditor-1.0.0.dmg (verteilbar)
```

`scripts/release-dmg.sh` ruft intern `scripts/notarize.sh` für die App auf und
notarisiert zusätzlich das `.dmg` (zwei Notarisierungs-Roundtrips → sowohl App
als auch DMG sind gestapelt, also auch beim ersten Offline-Start sauber).

**Nur die `.app`** (z. B. für Zip/Sparkle-Feed, ohne DMG):

```bash
xcodebuild -scheme schreibwerkstatt-focuseditor -configuration Release \
  -derivedDataPath build clean build
export DEV_ID_APP="Developer ID Application: David Berger (<TEAM_ID>)"
scripts/notarize.sh "build/Build/Products/Release/Focuseditor.app"
```

`notarize.sh` signiert mit Hardened Runtime + Timestamp, lädt zur Notarisierung
hoch (`--wait`), heftet das Ticket ans Bundle (`stapler`) und prüft mit `spctl`.

## Auto-Update (Sparkle)

Nur der DMG-Weg — im App-Store-Target ist Sparkle nicht enthalten (s. unten).
Die App bringt **Sparkle 2** mit (SPM, in den App-Code als `UpdaterController`
gekapselt, hinter `#if SPARKLE`). Sie prüft automatisch im Hintergrund auf neue Versionen und bietet
einen manuellen Check (App-Menü „Nach Updates suchen…" + Settings → Konto).

**Konfiguration (im Repo, einmalig erledigt):**
- `Config/Info.plist`: `SUFeedURL` (GitHub-„latest"-Appcast), `SUPublicEDKey`
  (EdDSA-Public-Key), `SUEnableInstallerLauncherService=YES` (Pflicht für die
  Sandbox), `SUEnableAutomaticChecks=YES`.
- `Config/Focuseditor.entitlements`: der Mach-Lookup auf Sparkles Installer-XPC
  (`$(PRODUCT_BUNDLE_IDENTIFIER)-spks`/`-spki`). Wird beim Signieren mit den von
  Xcode synthetisierten Sandbox-Entitlements gemerged (`ENABLE_APP_SANDBOX` etc.).

**EdDSA-Schlüssel (einmalig, lokal — NICHT im Git):**
Der **Privatkey liegt im Login-Keychain** dieses Macs (erzeugt mit Sparkles
`generate_keys`). Nur der Public-Key steht in der Info.plist. Geht der Keychain
verloren, kann **keine** neue Version mehr signiert werden, die alte Installs
akzeptieren → Keychain-Eintrag „Private key for signing Sparkle updates" sichern.
Neuer Schlüssel (nur falls nötig):

```bash
# Pfad zu den Sparkle-Tools (nach einem Build vorhanden):
SPK="$(find ~/Library/Developer/Xcode/DerivedData -path '*artifacts/sparkle/Sparkle/bin' | head -1)"
"$SPK/generate_keys"            # legt Privatkey im Keychain an, druckt SUPublicEDKey
# -> SUPublicEDKey in Config/Info.plist eintragen
```

**Release mit Appcast (jedes Release):**
`scripts/release-dmg.sh` (Build/Notarisierung wie oben) und das Publish-Skript
erzeugen das signierte `appcast.xml` automatisch und laden es **als zweites
Release-Asset** neben dem `.dmg` hoch:

```bash
export DEV_ID_APP="Developer ID Application: David Berger (<TEAM_ID>)"
PUBLISH=1 scripts/release-dmg.sh         # baut .dmg + appcast.xml, publisht beide
```

`scripts/publish-github-release.sh` ruft Sparkles `generate_appcast` (signiert
das `.dmg` mit dem Keychain-Privatkey, setzt die Download-URL auf den Tag-Asset-
Pfad) und legt das GitHub-Release `v<VERSION>` mit `.dmg` + `appcast.xml` als
`--latest` an. Damit löst die stabile `SUFeedURL`
(`…/releases/latest/download/appcast.xml`) immer auf den jüngsten Feed auf.

> Voraussetzung: vor dem Publish einmal builden (löst das Sparkle-Paket auf →
> `generate_appcast` ist da). Alternativer Pfad per `SPARKLE_BIN=…` überschreibbar.

> ⚠️ **Skript nie durch eine Pipe schicken** (`… | tee log`, `… | …`). `release-dmg.sh`
> läuft mit `set -euo pipefail`; bricht ein Schritt (z. B. ein transienter
> `notarytool submit`-Fehler) ab, **maskiert die Pipe den echten Exit-Code** — der
> Aufrufer sieht fälschlich `0`, obwohl das Release mittendrin stehenblieb (kein
> DMG/Release). Stattdessen direkt in eine Datei umlenken: `… > release.log 2>&1`,
> dann zählt `$?` des Skripts. **Falls die Notarisierung doch mal abbricht**
> (z. B. langer Wait wird vom Aufrufer-Prozess gekillt): die Apple-Submission läuft
> server-seitig weiter — Status mit `xcrun notarytool info <id>` prüfen und ab dem
> Punkt manuell weiterfahren (App stapeln → DMG bauen/signieren → DMG notarisieren/
> stapeln → `scripts/publish-github-release.sh <dmg>`), statt alles neu zu bauen.

## App Store (Target `Focuseditor-MAS`)

Der Store-Weg ist ein **zweites Target auf demselben Quellcode** — kein Fork, kein
zweiter Ordner (Übersicht: [CLAUDE.md](CLAUDE.md) „Zwei Distributionswege"). Alles
oben Beschriebene (Developer ID, Notarisierung, Sparkle, `release-dmg.sh`) gilt
**nur** für das DMG-Target und bleibt unverändert bestehen; beide Kanäle laufen
parallel weiter.

**Warum überhaupt getrennt:** Ein eigener Update-Mechanismus ist im App Store
verboten, und Sparkles Sandbox-Exception
(`com.apple.security.temporary-exception.mach-lookup.global-name` für die
Installer-XPC-Services) wird für App-Store-Profile praktisch nicht mehr erteilt —
ein Store-Build mit Sparkle scheitert schon an der Validierung.

**Was im MAS-Target anders ist:**
- Sparkle ist nicht gelinkt; der Code hängt an der Compilation Condition `SPARKLE`,
  die nur das DMG-Target setzt.
- `Config/Info-MAS.plist` statt `Config/Info.plist` — ohne die `SU*`-Keys, dafür mit
  `ITSAppUsesNonExemptEncryption=false` (erspart die Export-Compliance-Rückfrage).
- **Kein** `CODE_SIGN_ENTITLEMENTS`: Xcode synthetisiert `app-sandbox`,
  `network.client` und `files.user-selected` aus den `ENABLE_*`-Build-Settings.
- Bundle-ID identisch zum DMG-Target — Umsteiger behalten Keychain-Token,
  Einstellungen und den lokalen SQLite-Spiegel.
- Notarisierung entfällt (macht Apple beim Store-Ingest selbst).

**Build + Selbstkontrolle:**

```bash
xcodebuild -scheme Focuseditor-MAS -configuration Release \
  -derivedDataPath build/mas build -quiet

APP=build/mas/Build/Products/Release/Focuseditor.app
codesign -d --entitlements :- "$APP"        # nur app-sandbox/network.client/user-selected
ls "$APP/Contents/Frameworks" "$APP/Contents/XPCServices"   # beides existiert nicht
plutil -p "$APP/Contents/Info.plist" | grep '"SU'           # leer
```

Eigener `-derivedDataPath`, weil beide Targets ein `Focuseditor.app` produzieren
und sich sonst gegenseitig überschreiben.

**Store-Paket bauen — erledigt, verifiziert am 2026-08-01:**

```bash
scripts/archive-mas.sh      # Gegenprobe DMG-Schema -> Archiv -> Sanity-Check -> .pkg
```

Ergebnis: `build/mas/export/Focuseditor.pkg` (6,1 MB, Version 3.15/36). Nachweis am
entpackten Paket (`pkgutil --expand-full`):

- App: `Authority=Apple Distribution: David Berger (TQA2JLKT87)`
- `Contents/embedded.provisionprofile` vorhanden (Mac-App-Store-Profil)
- Entitlements exakt `application-identifier`, `team-identifier`, `app-sandbox`,
  `files.user-selected.read-only`, `network.client` — keine `temporary-exception`
- `.pkg`: `3rd Party Mac Developer Installer: David Berger (TQA2JLKT87)`

**`-allowProvisioningUpdates` ist Pflicht** — an `archive` *und* `exportArchive`
(steht im Skript). Damit legt Xcode App ID, die Zertifikate „Apple Distribution" +
„3rd Party Mac Developer Installer" und das Mac-App-Store-Profil beim ersten
Archiv **selbst** an; es braucht keinen Klick im Developer-Portal. Nebenbefund: der
Installer-Cert erscheint nicht in `security find-identity -p codesigning` (nicht
codesigning-fähig) — der richtige Nachweis ist `pkgutil --check-signature`.

**Noch offen (Apple-Kontoarbeit, unabhängig vom Code):**
1. **App-Record in App Store Connect** — fehlt noch; `xcrun altool --list-apps
   --type macos --apiKey … --apiIssuer …` liefert eine leere Liste. Anlegen:
   appstoreconnect.apple.com → Apps → **+** → macOS → Bundle-ID
   `David-Berger.schreibwerkstatt-focuseditor` → Name, Primärsprache, SKU.
   **Ohne den Record ist kein Upload möglich:** `altool --upload-package` verlangt
   `--apple-id` = die *numerische* App-ID aus dem Record (nicht die Bundle-ID).
   Danach hochladen mit
   ```bash
   UPLOAD=1 ASC_APP_ID=<numerische App-ID> scripts/archive-mas.sh
   ```
   oder das fertige `.pkg` in Transporter ziehen. Im Release-Workflow steckt der
   Paketbau hinter `/release appstore` bzw. `/release beide`.
2. **Kontolöschung in-app** (Guideline 5.1.1(v)) — fehlt noch, wahrscheinlicher
   Reject-Grund.
3. **`MACOSX_DEPLOYMENT_TARGET` senken** — das gebaute Paket trägt
   `LSMinimumSystemVersion = 26.5`, ist im Store also für fast niemanden
   installierbar. Vor der ersten Einreichung auf 14.0/15.0 ziehen und die dabei
   auffallenden macOS-26-only-APIs abfangen. (Hochladen und in TestFlight prüfen
   geht auch vorher — nur eben nicht einreichen.)
4. Metadaten: **liegen fertig in [AppStore/](AppStore/)** — Listings de/en
   (Name, Untertitel, Keywords, Beschreibung, Neuerungen, URLs), Screenshots
   (je vier, 2880×1800, ohne Alphakanal), App-Privacy-Deklaration und
   Altersfreigabe (4+). Eintrage-Reihenfolge und die Skripte
   (`appstore-screenshots.sh`, `appstore-check-lengths.sh`) stehen in
   [AppStore/README.md](AppStore/README.md).
5. Review-Notes: fertiger Text in [REVIEW-NOTES.md](REVIEW-NOTES.md) — Demo-Zugang
   („Demo öffnen" ist im Store-Build bewusst aktiv, Ein-Klick-Login für den
   Reviewer) und die Erklärung, dass das OTA-Editor-Bundle von WebKit
   interpretierter Code ist (Guideline-2.5.2-Ausnahme), der den Funktionsumfang
   nicht verändert. Block dort 1:1 in *App Review Information → Notes* kopieren.
