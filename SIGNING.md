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
