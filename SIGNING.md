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

## Später (Auto-Update)
Sparkle braucht zusätzlich ein **EdDSA-Keypair** (eigener Sparkle-Schlüssel,
unabhängig vom Apple-Zertifikat) — kommt erst mit der Sparkle-Integration.
