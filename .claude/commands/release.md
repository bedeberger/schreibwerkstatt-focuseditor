---
description: Version bumpen, builden, committen + veröffentlichen — als notarisiertes .dmg (GitHub-Release inkl. Sparkle-Appcast) und/oder als App-Store-Paket
---

Führe den kompletten Release-Workflow für **schreibwerkstatt-focuseditor** (nativer macOS-Client) aus. Dieser Command ist die **gezielte Freigabe** des Users — wenn er aufgerufen wird, den ganzen Ablauf ohne weitere Rückfrage durchziehen (außer ein Build-/Notarisierungs-Schritt schlägt fehl, dann stoppen und melden).

## Argumente (`$ARGUMENTS`, Reihenfolge egal, beide optional)

- **Bump-Höhe:** `patch` | `minor` | `major`. Fehlt sie, aus den seit dem letzten Tag liegenden Änderungen ableiten — neue nutzersichtbare Features → `minor`, sonst `patch`, im Zweifel `patch`.
- **Kanal:** `dmg` (Default) | `appstore` | `beide`.

```
/release                  → DMG, Bump-Höhe abgeleitet
/release minor            → DMG, Minor-Bump
/release appstore         → nur App Store
/release minor appstore   → App Store, Minor-Bump
/release beide            → ein Bump, danach DMG-Release UND App-Store-Archiv
```

Es gibt **zwei Distributionswege auf einem Quellcode** (Hintergrund: [CLAUDE.md](CLAUDE.md) „Zwei Distributionswege"). Der Versions-Bump passiert **einmal** am Anfang und gilt für beide — beide Targets lesen dieselbe [Version.xcconfig](Version.xcconfig). Nie pro Kanal separat bumpen, sonst laufen DMG- und Store-Version auseinander.

Die Schritte 1–5 sind für alle Kanäle identisch. Danach verzweigt es:

| Schritt | `dmg` | `appstore` |
|---|---|---|
| 6 Tag + Push | ✅ | ❌ (kein Tag, aber Commit + `git push origin main`) |
| 7 notarisiertes .dmg + GitHub-Release | ✅ | ❌ |
| 8 Archiv + .pkg-Export | ❌ | ✅ |

Bei `beide`: erst 6 + 7, dann 8.

Schritte:

1. **Stand prüfen:** `git status` + `git diff --stat` (und ggf. `git log --oneline <letzter-tag>..HEAD`) ansehen, damit die Commit-Message + Release-Notes die Änderungen korrekt beschreiben. Aktuelle Version aus [Version.xcconfig](Version.xcconfig) lesen (`MARKETING_VERSION` + `CURRENT_PROJECT_VERSION`).
2. **Bumpen (nur in [Version.xcconfig](Version.xcconfig) — SSoT, nie woanders hartcodieren):** `MARKETING_VERSION` nach SemVer anheben (Höhe s.o.) **und** `CURRENT_PROJECT_VERSION` um genau 1 erhöhen. Beide Felder gemeinsam. Diese Versionsnummern stehen für CFBundleShortVersionString, den GitHub-Tag `v<…>`, den .dmg-Dateinamen und die Sparkle-Update-Erkennung.
3. **Debug-Build verifizieren (Pflicht):**
   ```bash
   xcodebuild -scheme schreibwerkstatt-focuseditor -configuration Debug build -quiet
   ```
   Muss `** BUILD SUCCEEDED **` liefern. Bei Fehler: stoppen und fixen, nicht weitermachen.

   Wurde im Release-Diff Sparkle-Code, eine Info.plist oder die Projektdatei berührt, **zusätzlich** das App-Store-Target bauen — ein fehlender `#if SPARKLE`-Guard bricht sonst nur den anderen Kanal, und das fällt erst beim nächsten Store-Release auf:
   ```bash
   xcodebuild -scheme Focuseditor-MAS -configuration Release -derivedDataPath build/mas build -quiet
   ```
   (Bei Kanal `appstore`/`beide` macht [scripts/archive-mas.sh](scripts/archive-mas.sh) diese Gegenprobe in Schritt 8 ohnehin selbst.)
4. **Guards (Pflicht):**
   ```bash
   xcodebuild -scheme schreibwerkstatt-focuseditor -configuration Debug test \
     -only-testing:schreibwerkstatt-focuseditorTests/SourceFileSizeTests \
     -only-testing:schreibwerkstatt-focuseditorTests/DistributionTargetsTests
   ```
   Beide müssen grün sein. Datei-Größe schlägt an → siehe CLAUDE.md (aufteilen oder bewusst in `allowedOverLimit`). `DistributionTargetsTests` schlägt an → die zwei Kanäle sind auseinandergelaufen (Plist-Key nur in einer Datei, Sparkle/Entitlements im MAS-Target, Bundle-ID oder Quell-Gruppe verschieden, `Version.xcconfig` nicht mehr projektweit). Das **vor** dem Bump fixen — es würde sonst genau den anderen Kanal treffen.
5. **Committen:** Alle Änderungen `git add -A`, Commit mit aussagekräftiger Message — Features in Stichpunkten + Abschlusszeile im Repo-Stil `version <MARKETING_VERSION> (build <CURRENT_PROJECT_VERSION>)`. Abschliessend der Co-Author-Trailer:
   ```
   Co-Authored-By: Claude <MODELL> <noreply@anthropic.com>
   ```
   `<MODELL>` ist das Modell, das den Commit **tatsächlich** macht — also der Trailer, den die laufende Umgebung vorgibt (z. B. `Claude Opus 5`). Hier bewusst **kein** fester Name: eine hartkodierte Version veraltet mit dem nächsten Modellwechsel und schreibt dann eine falsche Zuordnung in die Historie.
6. **Taggen + pushen** *(Kanal `dmg`/`beide`)*: `git tag v<MARKETING_VERSION>`, dann `git push origin main` **und** `git push origin v<MARKETING_VERSION>`.
   *(Kanal `appstore`: nur `git push origin main` — der Tag gehört zum GitHub-Release und wäre ohne DMG-Asset irreführend. Wird später ein `beide`-Release derselben Version nachgezogen, kommt der Tag dort dazu.)*
7. **Notarisiertes .dmg bauen + als GitHub-Release veröffentlichen** *(Kanal `dmg`/`beide`)*:
   ```bash
   PUBLISH=1 scripts/release-dmg.sh
   ```
   Das Skript zieht die Version automatisch aus [Version.xcconfig](Version.xcconfig) und erledigt in einem Rutsch: frischer Release-Build → signieren + **notarisieren** + stapeln ([scripts/notarize.sh](scripts/notarize.sh)) → Drag-to-Applications-.dmg → .dmg signieren + notarisieren → Gatekeeper-Check → dann [scripts/publish-github-release.sh](scripts/publish-github-release.sh): **Sparkle-`appcast.xml`** erzeugen + EdDSA-signieren und zusammen mit dem `Focuseditor-<version>.dmg` als `--latest`-Release unter dem (in Schritt 6 bereits gepushten) Tag `v<version>` hochladen.
   - Voraussetzungen liegen in [scripts/release.env](scripts/release.env) (`DEV_ID_APP` + notarytool-Key) und `gh auth` muss eingeloggt sein — beides ist eingerichtet. Schlägt Notarisierung/Upload fehl → Fehler melden, **nicht** den lokalen Commit/Tag zurückrollen (der Push ist schon erfolgt).

8. **App-Store-Paket bauen** *(Kanal `appstore`/`beide`)*:
   ```bash
   scripts/archive-mas.sh
   ```
   Das Skript baut zuerst das DMG-Schema als Gegenprobe, archiviert dann das Target `Focuseditor-MAS`, prüft das archivierte Bundle auf die App-Store-Blocker (kein Sparkle.framework, kein `Contents/XPCServices`, keine `temporary-exception`-Entitlement, keine `SU*`-Keys) und exportiert nach `build/mas/export/*.pkg` ([Config/ExportOptions-MAS.plist](Config/ExportOptions-MAS.plist)).
   - **Kein** Tag, **kein** GitHub-Release, **keine** Notarisierung — das macht Apple beim Store-Ingest.
   - Der **Upload ist manuell** (Transporter oder Xcode-Organizer). `UPLOAD=1 scripts/archive-mas.sh` versucht es per `altool`, braucht dafür aber einen App-Store-Connect-Key mit der Rolle **App Manager**; der vorhandene Notarisierungs-Key hat nur „Developer" und schlägt dabei fehl. Das ist dann kein Problem des Pakets — auf Transporter ausweichen.
   - **Voraussetzungen** (Apple-Kontoarbeit, s. [SIGNING.md](SIGNING.md) „App Store"): App ID registriert, Zertifikate „Apple Distribution" + „Mac Installer Distribution", Provisioning-Profil *Mac App Store*, App-Record in App Store Connect. Solange das fehlt, läuft Archiv + Sanity-Check durch und der **Export bricht mit einem Signier-/Profilfehler ab** — das melden, nicht umgehen und **nicht** den Commit/Tag zurückrollen.
   - Nach dem Upload in App Store Connect: Build der Version zuordnen, „Was ist neu"-Text, Metadaten, zur Review einreichen. **Bei einem Reject** vor dem erneuten Upload `CURRENT_PROJECT_VERSION` erhöhen — Apple nimmt keine Build-Nummer zweimal an.

**Warum notarisiertes .dmg + Appcast (nicht nur ein Debug-Artefakt):** Der Server (Mutterprojekt) liest das `latest`-Release und bietet das .dmg unter Profil-Einstellungen zum Download an; **Sparkle** zieht `releases/latest/download/appcast.xml` für In-App-Auto-Updates. Beides setzt ein mit „Developer ID Application" signiertes, notarisiertes Image samt EdDSA-signiertem Appcast voraus (siehe [SIGNING.md](SIGNING.md)). Die Versionserkennung vergleicht den Tag (`v` gestrippt) per SemVer gegen die laufende App.

**Tastaturkürzel-/Lokalisierungs-Pflichten** (CLAUDE.md): Wurde im Release-Diff ein Shortcut oder ein UI-String berührt, vor dem Commit prüfen, dass [ShortcutsHelpView.swift](schreibwerkstatt-focuseditor/ShortcutsHelpView.swift) bzw. die Kataloge [mac-de.json](schreibwerkstatt-focuseditor/Localization/mac-de.json)/[mac-en.json](schreibwerkstatt-focuseditor/Localization/mac-en.json) mitgezogen wurden.

Am Ende: knappe Zusammenfassung mit der neuen Version (Marketing + Build), Commit-Hash und — je nach Kanal — Release-URL und/oder Pfad zum `.pkg` samt der noch offenen manuellen Schritte in App Store Connect.
