# App-Store-Metadaten

Alles, was in App Store Connect eingetragen wird — fertig zum Kopieren. Der
Code-Teil (zweites Target, Signierung, `.pkg`-Export) steht in
[SIGNING.md](../SIGNING.md) „App Store“; hier liegt nur das Drumherum.

| Datei | Wofür in ASC |
|---|---|
| [listing-de.md](listing-de.md) | App-Informationen + Version → **Deutsch** (Primärsprache) |
| [listing-en.md](listing-en.md) | Version → **Englisch** |
| [app-privacy.md](app-privacy.md) | App-Datenschutz (Fragebogen) |
| [age-rating.md](age-rating.md) | Altersfreigabe (Fragebogen) → **4+** |
| [../REVIEW-NOTES.md](../REVIEW-NOTES.md) | App-Prüfungsinformationen (Demo-Zugang, 2.5.2) |
| [screenshots/de/](screenshots/de/) · [screenshots/en/](screenshots/en/) | Screenshots, je 4 Stück, 2880×1800 |

## Stand in App Store Connect (per API geprüft, 2026-08-03)

Der App-Record existiert: **ID `6797073919`**, SKU `SWK-FOCUSEDITOR-MAC`,
Primärsprache de-DE, Status *Prepare for Submission*.

| | Stand |
|---|---|
| Deutsche Texte | **drin** — Untertitel, Beschreibung und Keywords stimmen zeichengenau mit [listing-de.md](listing-de.md) überein |
| Screenshots de | **drin** — vier Stück im Set `APP_DESKTOP`, 2880×1800, identisch mit `screenshots/de/` |
| Datenschutz-URL | **drin** (`…/datenschutz`) |
| Altersfreigabe | **drin** — 4+ (`FOUR_PLUS`) |
| Kategorien | **fehlen** — s. [listing-de.md](listing-de.md), Abschnitt „Kategorie“ |
| Inhalte Dritter (`contentRightsDeclaration`) | **fehlt** |
| Englisch | **fehlt komplett** — weder App-Info noch Version in `en`, obwohl [listing-en.md](listing-en.md) und `screenshots/en/` bereitliegen |
| Versionsnummer | **stimmt nicht** — ASC steht auf 3.17, `Version.xcconfig` auf 3.16 |
| Build | **keiner hochgeladen**, keiner verknüpft |

Nicht prüfbar mit dem vorhandenen API-Schlüssel (Rolle *Developer*):
App-Datenschutz-Fragebogen (alle API-Pfade antworten 404) sowie Preis und
Verfügbarkeit (403) — beides im Web bestätigen.

## Reihenfolge beim Einrichten

1. App-Record anlegen (Bundle-ID `David-Berger.schreibwerkstatt-focuseditor`),
   Name/Untertitel/Kategorien aus [listing-de.md](listing-de.md). *(erledigt bis
   auf die Kategorien)*
2. Altersfreigabe-Fragebogen → [age-rating.md](age-rating.md). *(erledigt, 4+)*
3. App-Datenschutz → [app-privacy.md](app-privacy.md). Muss **vor** der ersten
   Einreichung vollständig sein, sonst blockiert ASC das Absenden.
4. Version: Beschreibung, Neuerungen, Keywords, URLs, Screenshots — auf Deutsch
   erledigt, auf Englisch offen. Versionsnummer mit `Version.xcconfig`
   abgleichen.
5. Build hochladen (`scripts/archive-mas.sh`, dann Transporter/Organizer).
6. Prüfungsinformationen → [../REVIEW-NOTES.md](../REVIEW-NOTES.md).

## Screenshots

Vier pro Sprache, aufgenommen am **echten Build** gegen das öffentliche
Demo-Konto (`demo.schreibwerkstatt.app`, Beispielbuch „Die Verwandlung“):

| # | Motiv |
|---|---|
| 01 | Schreibfläche hell, Papier-Ton — die Kernansicht |
| 02 | Seiten-Picker (⌘O) mit „Zuletzt geöffnet“ |
| 03 | Einstellungen → Typografie (Schrift, Zeilenhöhe, Spaltenbreite, Papier) |
| 04 | Schreibfläche dunkel, Nacht-Ton |

Format: 2880×1800 (= 1440×900 pt auf Retina), PNG **ohne Alphakanal** — ASC
weist transparente Screenshots zurück. Neu aufnehmen:

```bash
scripts/appstore-screenshots.sh de
scripts/appstore-screenshots.sh en
```

Das Skript baut dafür eine **isolierte Kopie** der App (eigene Bundle-ID *und*
eigener Keychain-Service). Der Grund steht im Skriptkopf und ist wichtig: der
Keychain-Eintrag hängt an einer festen (service, account)-Kombination, nicht am
Server — ein Demo-Login aus der normalen App überschriebe das
Produktions-Gerätetoken, das nur einmal angezeigt wird.

**Grenze:** Synthetische Tastendrücke erreichen die WKWebView nicht (nur
AppKit-Shortcuts wie ⌘O/⌘, kommen an). Aufnahmen, die eine Interaktion *im
Text* brauchen — Synonym-Menü (⌘⇧S), Rechtschreib-Popover — müssen von Hand
gemacht werden. Fenster dafür auf exakt 1440×900 pt setzen und mit
`screencapture -x -R 60,60,1440,900` aufnehmen, danach
`swift scripts/strip-alpha.swift` drüberlaufen lassen.

## Textlängen prüfen

```bash
scripts/appstore-check-lengths.sh
```

Liest die Code-Blöcke aus den beiden Listing-Dateien und vergleicht sie mit
Apples Limits (Name 30, Untertitel 30, Promo 170, Keywords 100, Beschreibung
4000). Läuft ohne Netz.

## Offene Punkte vor der ersten Einreichung

Nicht Metadaten, aber blockierend — Details in [SIGNING.md](../SIGNING.md):

- ✅ **Kategorien** — `LSApplicationCategoryType = public.app-category.productivity`
  (Build und Store-Eintrag stimmen überein), Hintergrund in [listing-de.md](listing-de.md).
- ✅ **Kontolöschung in der App** (Richtlinie 5.1.1(v)) — implementiert, s. CLAUDE.md
  „Konto löschen (in-app)".
- ✅ **`MACOSX_DEPLOYMENT_TARGET`** — auf 14.0 gesenkt.
- **Support-URL**: zeigt vorerst auf die Startseite. Sobald es eine eigene
  Hilfe-/Kontaktseite gibt, in beiden Listing-Dateien nachziehen.
