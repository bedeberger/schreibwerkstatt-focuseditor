# App-Store-Listing — Deutsch (Primärsprache)

Alles hier wird 1:1 in App Store Connect → *App-Informationen* bzw.
*Version → Deutsch* eingetragen. Zeichenzahlen sind Apple-Limits; die
geprüften Ist-Werte stehen in Klammern (`scripts/appstore-check-lengths.sh`).

## App-Informationen (sprachübergreifend)

| Feld | Wert |
|---|---|
| Bundle-ID | `David-Berger.schreibwerkstatt-focuseditor` |
| Primäre Kategorie | Produktivität — **aber siehe Warnung unten** |
| Sekundäre Kategorie | Bildung |
| Copyright | 2026 David Berger |
| Altersfreigabe | 4+ (Fragebogen: [age-rating.md](age-rating.md)) |
| Preis | Gratis, keine In-App-Käufe |

> **Kategorie stimmt noch nicht überein.** Beide Targets bauen mit
> `INFOPLIST_KEY_LSApplicationCategoryType = public.app-category.books`
> (pbxproj, vier Stellen) — das widerspricht „Produktivität“ in ASC, und Apple
> mahnt Abweichungen zwischen Info.plist und gewählter Kategorie an. Eins von
> beiden angleichen, **vor** dem ersten Upload:
> - **Produktivität** (Empfehlung): Build-Setting auf
>   `public.app-category.productivity` ziehen. Grössere Zielgruppe, und die App
>   ist ein Schreibwerkzeug, kein Lesegerät.
> - **Bücher**: hier „Produktivität“ durch „Bücher“ ersetzen, dann bleibt der
>   Code unangetastet. Weniger Konkurrenz, aber „Bücher“ suggeriert Lesen.

## Name (max. 30)

```
Schreibwerkstatt Focuseditor
```

## Untertitel (max. 30)

```
Fokussiert schreiben, offline
```

## Promotional Text (max. 170, ohne Review änderbar)

```
Eine Seite, eine Schreiblinie, sonst nichts. Deine Texte liegen zuerst lokal auf dem Mac und synchronisieren sich mit deinem Schreibwerkstatt-Konto, sobald Netz da ist.
```

## Keywords (max. 100, kommagetrennt, keine Leerzeichen nach Komma)

```
schreiben,fokus,ablenkungsfrei,roman,manuskript,autor,offline,lektorat,synonyme,textverarbeitung
```

Nicht in die Keywords: der App-Name und die Kategorie — Apple indexiert die
ohnehin. „Editor“, „Buch“ und „Text“ stecken bereits in Name/Untertitel/
Beschreibung.

## Beschreibung (max. 4000)

```
Focuseditor ist der ablenkungsfreie Schreibmodus der Schreibwerkstatt als native Mac-App: eine Seite, eine Schreiblinie, sonst nichts. Kein Buchorganizer, keine Analysekarten, keine Werkzeugleisten-Wüste — nur der Text, an dem du gerade arbeitest.

BEGLEIT-APP — BITTE VOR DEM LADEN LESEN
Focuseditor gehört zur Schreibwerkstatt (schreibwerkstatt.app) und braucht ein Konto auf einem Schreibwerkstatt-Server. Einen eigenständigen Modus ohne Server gibt es nicht. Zum Ausprobieren ist ein Demo-Zugang eingebaut: ein Klick im Anmeldefenster, ohne eigenes Konto.

ZUERST LOKAL, DANN SYNC
Jeder Tastendruck landet zuerst in einem lokalen Speicher auf deinem Mac — nicht im Netz. Die App wartet nie auf eine Verbindung. Im Hintergrund gleicht sie ab, sobald Netz da ist; nach dem ersten Start arbeitest du vollständig offline weiter, im Zug genauso wie am Schreibtisch. Ändern sich dieselbe Seite hier und anderswo, führt die App die Absätze zusammen, statt eine Fassung zu überschreiben.

FOKUS
• Schreibmaschinen-Modus: die aktive Zeile bleibt ruhig auf der Schreiblinie
• Umgebung abdunkeln — wahlweise alles ausser der Schreibzeile oder ein Fenster von drei Absätzen
• Vollbild mit Werkzeugleiste, die sich von selbst wegblendet
• Seiten öffnen über einen Picker mit „Zuletzt geöffnet“ (⌘O)

TYPOGRAFIE, DIE DU EINSTELLST
Schriftart und -grösse, Zeilenhöhe, Spaltenbreite und Papierton — vom hellen Papier bis zum dunklen Schreibtisch. Hell, dunkel oder dem System folgend.

HILFE BEIM SCHREIBEN
• Rechtschreib- und Grammatikprüfung, mit eigenem Wörterbuch
• Synonyme mit ⌘⇧S: Thesaurus und KI-Vorschläge, passend zum Satz
• Anführungszeichen auf den Stil des Buchs ziehen — «Schweiz», „Deutschland“ oder “englisch”
• Wortzahl, Lesezeit, Tagesziel und Schreibzeit im Blick
• Lektorat der offenen Seite anstossen, das auf deinem Server läuft

AUF DEM MAC ZU HAUSE
Deutsch und Englisch, Tastaturkürzel-Übersicht mit ⌘?, Dunkelmodus, Vollbild, Kontextmenü — eine echte Mac-App, kein Browserfenster im Anzug.

DEINE TEXTE, DEIN SERVER
Die App spricht ausschliesslich mit dem Server, den du selbst einträgst. Das Gerätetoken liegt im macOS-Schlüsselbund und verlässt den Mac nicht im Klartext. Keine Werbung, kein Tracking, keine Analyse durch Dritte. Die KI-gestützten Funktionen (Synonyme, Lektorat) laufen über deinen Server; welcher KI-Dienst dort arbeitet, bestimmt dessen Betreiber — nachzulesen in der Datenschutzerklärung.
```

## Neue Funktionen in dieser Version (max. 4000) — 3.15

```
Erste Fassung im Mac App Store.

• Ablenkungsfreier Schreibmodus für genau eine Seite, voll offline-fähig
• Lokaler Speicher mit Hintergrund-Sync zu deinem Schreibwerkstatt-Konto
• Schreibmaschinen-Modus, Fokus-Abdunklung und einstellbare Typografie
• Rechtschreibprüfung, Synonyme (⌘⇧S) und Anführungszeichen-Normalisierung
• Wortzahl, Tagesziel und Schreibzeit
• Deutsch und Englisch
```

## URLs

| Feld | Wert |
|---|---|
| Support-URL | `https://schreibwerkstatt.app` |
| Marketing-URL | `https://schreibwerkstatt.app` |
| Datenschutzrichtlinie | `https://schreibwerkstatt.app/datenschutz` |

Die Support-URL zeigt bewusst auf die Startseite: dort stehen Funktionsumfang,
Registrierung und der Hinweis auf den Betreiber. Sobald es eine eigene
Hilfe-/Kontaktseite gibt, hier und in der englischen Fassung nachziehen.
