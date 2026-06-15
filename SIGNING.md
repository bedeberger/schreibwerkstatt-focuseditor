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
- ✅ Notarisierungs-Skript: [scripts/notarize.sh](scripts/notarize.sh).

## Noch offen — einmalig erledigen

### 1. Apple Developer Program (kostenpflichtig, ~99 $/Jahr)
Das kostenlose „Personal Team" (`TQA2JLKT87`) reicht **nicht** — es kann kein
„Developer ID Application"-Zertifikat ausstellen.
→ developer.apple.com → Account → Enroll.

### 2. „Developer ID Application"-Zertifikat erstellen
Xcode → Settings → Accounts → Account wählen → **Manage Certificates** →
**+** → **Developer ID Application**. Landet im Login-Keychain.
Prüfen:
```bash
security find-identity -p codesigning -v
# sollte "Developer ID Application: David Berger (TEAMID)" zeigen (heute: 0 Identities)
```

### 3. Team-ID im Projekt setzen
Xcode → Target → **Signing & Capabilities** → Team auswählen
(setzt `DEVELOPMENT_TEAM`). Für die Release-Verteilung Signing ggf. auf
**Manual** + Identity „Developer ID Application" stellen.

### 4. notarytool-Zugang anlegen (einmalig)
App-spezifisches Passwort auf appleid.apple.com erzeugen, dann:
```bash
xcrun notarytool store-credentials swk-notary \
  --apple-id "david.berger@dotag.ch" \
  --team-id "<TEAM_ID>" \
  --password "<app-specific-password>"
```

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
