# Signieren & Notarisieren (Verteilung außerhalb App Store)

Ziel: Die App läuft auf fremden Macs ohne Gatekeeper-Warnung. Dafür braucht es
ein **Developer-ID-Zertifikat** + **Notarisierung** durch Apple.

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

Die App bringt **Sparkle 2** mit (SPM, in den App-Code als `UpdaterController`
gekapselt). Sie prüft automatisch im Hintergrund auf neue Versionen und bietet
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
