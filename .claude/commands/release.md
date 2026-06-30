---
description: Version bumpen, builden, committen, taggen, pushen + notarisiertes .dmg als GitHub-Release (inkl. Sparkle-Appcast) anlegen
---

Führe den kompletten Release-Workflow für **schreibwerkstatt-focuseditor** (nativer macOS-Client) aus. Dieser Command ist die **gezielte Freigabe** des Users — wenn er aufgerufen wird, den ganzen Ablauf ohne weitere Rückfrage durchziehen (außer ein Build-/Notarisierungs-Schritt schlägt fehl, dann stoppen und melden).

Optionales Argument `$ARGUMENTS` = gewünschte Bump-Höhe (`patch` | `minor` | `major`). Wenn leer: Höhe aus den seit dem letzten Tag liegenden Änderungen ableiten — neue nutzersichtbare Features → `minor`, sonst `patch`, im Zweifel `patch`.

Schritte:

1. **Stand prüfen:** `git status` + `git diff --stat` (und ggf. `git log --oneline <letzter-tag>..HEAD`) ansehen, damit die Commit-Message + Release-Notes die Änderungen korrekt beschreiben. Aktuelle Version aus [Version.xcconfig](Version.xcconfig) lesen (`MARKETING_VERSION` + `CURRENT_PROJECT_VERSION`).
2. **Bumpen (nur in [Version.xcconfig](Version.xcconfig) — SSoT, nie woanders hartcodieren):** `MARKETING_VERSION` nach SemVer anheben (Höhe s.o.) **und** `CURRENT_PROJECT_VERSION` um genau 1 erhöhen. Beide Felder gemeinsam. Diese Versionsnummern stehen für CFBundleShortVersionString, den GitHub-Tag `v<…>`, den .dmg-Dateinamen und die Sparkle-Update-Erkennung.
3. **Debug-Build verifizieren (Pflicht):**
   ```bash
   xcodebuild -scheme schreibwerkstatt-focuseditor -configuration Debug build -quiet
   ```
   Muss `** BUILD SUCCEEDED **` liefern. Bei Fehler: stoppen und fixen, nicht weitermachen.
4. **Datei-Größen-Guard (Pflicht):**
   ```bash
   xcodebuild -scheme schreibwerkstatt-focuseditor -configuration Debug test \
     -only-testing:schreibwerkstatt-focuseditorTests/SourceFileSizeTests
   ```
   Muss grün sein. Schlägt er an → siehe CLAUDE.md (aufteilen oder bewusst in `allowedOverLimit`).
5. **Committen:** Alle Änderungen `git add -A`, Commit mit aussagekräftiger Message — Features in Stichpunkten + Abschlusszeile im Repo-Stil `version <MARKETING_VERSION> (build <CURRENT_PROJECT_VERSION>)`. Mit Trailer:
   ```
   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
   ```
6. **Taggen + pushen:** `git tag v<MARKETING_VERSION>`, dann `git push origin main` **und** `git push origin v<MARKETING_VERSION>`.
7. **Notarisiertes .dmg bauen + als GitHub-Release veröffentlichen:**
   ```bash
   PUBLISH=1 scripts/release-dmg.sh
   ```
   Das Skript zieht die Version automatisch aus [Version.xcconfig](Version.xcconfig) und erledigt in einem Rutsch: frischer Release-Build → signieren + **notarisieren** + stapeln ([scripts/notarize.sh](scripts/notarize.sh)) → Drag-to-Applications-.dmg → .dmg signieren + notarisieren → Gatekeeper-Check → dann [scripts/publish-github-release.sh](scripts/publish-github-release.sh): **Sparkle-`appcast.xml`** erzeugen + EdDSA-signieren und zusammen mit dem `Focuseditor-<version>.dmg` als `--latest`-Release unter dem (in Schritt 6 bereits gepushten) Tag `v<version>` hochladen.
   - Voraussetzungen liegen in [scripts/release.env](scripts/release.env) (`DEV_ID_APP` + notarytool-Key) und `gh auth` muss eingeloggt sein — beides ist eingerichtet. Schlägt Notarisierung/Upload fehl → Fehler melden, **nicht** den lokalen Commit/Tag zurückrollen (der Push ist schon erfolgt).

**Warum notarisiertes .dmg + Appcast (nicht nur ein Debug-Artefakt):** Der Server (Mutterprojekt) liest das `latest`-Release und bietet das .dmg unter Profil-Einstellungen zum Download an; **Sparkle** zieht `releases/latest/download/appcast.xml` für In-App-Auto-Updates. Beides setzt ein mit „Developer ID Application" signiertes, notarisiertes Image samt EdDSA-signiertem Appcast voraus (siehe [SIGNING.md](SIGNING.md)). Die Versionserkennung vergleicht den Tag (`v` gestrippt) per SemVer gegen die laufende App.

**Tastaturkürzel-/Lokalisierungs-Pflichten** (CLAUDE.md): Wurde im Release-Diff ein Shortcut oder ein UI-String berührt, vor dem Commit prüfen, dass [ShortcutsHelpView.swift](schreibwerkstatt-focuseditor/ShortcutsHelpView.swift) bzw. die Kataloge [mac-de.json](schreibwerkstatt-focuseditor/Localization/mac-de.json)/[mac-en.json](schreibwerkstatt-focuseditor/Localization/mac-en.json) mitgezogen wurden.

Am Ende: knappe Zusammenfassung mit der neuen Version (Marketing + Build), Commit-Hash und Release-URL.
