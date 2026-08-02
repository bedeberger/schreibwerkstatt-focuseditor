# Altersfreigabe (App Store Connect → Altersfreigabe)

**Ergebnis: 4+.** Die App zeigt ausschliesslich Text, den der angemeldete
Nutzer selbst schreibt, und hat keine Werbung, keine Käufe, keinen Browser.

Apple hat den Fragebogen 2025 umgebaut (Stufen 4+/9+/13+/16+/18+, eigene
Abschnitte für Fähigkeiten). Die Formulierungen können darum leicht abweichen —
massgeblich ist unten jeweils die Begründung, nicht der exakte Fragetext.

## Inhaltskategorien — durchgehend „Keine“

Gewalt (comichaft, realistisch, grafisch) · Schimpfwörter/derber Humor ·
sexuelle Inhalte/Nacktheit · anzügliche Themen · Schreckens-/Horror-Themen ·
Alkohol, Tabak, Drogen · simuliertes Glücksspiel · medizinische Informationen ·
Waffen · Diskriminierung.

Die App liefert **keine** eigenen Inhalte. Sie zeigt einen leeren Schreibbereich
und darin den Text des angemeldeten Kontos.

## Fähigkeiten

| Frage | Antwort | Begründung |
|---|---|---|
| Uneingeschränkter Web-Zugriff | **Nein** | Die WebView lädt ausschliesslich `swk-app://` aus dem lokalen Cache; eine Server-URL wird nie geladen (harte Regel in [CLAUDE.md](../CLAUDE.md)). Angeklickte `http(s)`-Links werden abgelehnt und an den Standard-Browser übergeben — es gibt keinen In-App-Browser und keine Adresszeile. |
| Glücksspiel / Wettbewerbe | Nein | Nicht vorhanden. |
| In-App-Käufe / Werbung | Nein | Die App ist gratis, ohne Käufe und ohne Werbe-SDK. |
| Nachrichten / Chat zwischen Nutzern | **Nein** | Der Client hat keine Chat-, Kommentar- oder Nachrichtenfunktion. (Die Web-Plattform hat einen KI-Chat — der ist bewusst **nicht** Teil dieser App.) |
| Für Kinder gemacht („Made for Kids“) | Nein | Zielgruppe sind schreibende Erwachsene; das Kids-Programm bringt zusätzliche Auflagen ohne Nutzen. |

## Der eine Punkt, der eine Entscheidung braucht: benutzergenerierte Inhalte

**Empfehlung: „Nein“.** Begründung, die auch gegenüber dem Review trägt:

- Die App zeigt **nur** Inhalte des angemeldeten Kontos: die Seiten der Bücher,
  auf die dieses Konto Zugriff hat.
- Es gibt kein Entdecken, keine Profile, keinen öffentlichen Feed, kein Teilen
  an Fremde, keine Kommentare — keinen Weg, an fremde Inhalte zu gelangen.
- Wer Zugriff auf ein Buch bekommt, entscheidet ausserhalb der App auf dem
  Server des Betreibers (Einladung, z. B. für die Lektorats-Rolle).

**Wo die Nuance liegt:** Ein Buch auf dem Server kann mehrere berechtigte
Bearbeiter haben — der Konflikt-Dialog nennt darum den anderen Bearbeiter
namentlich. Streng gelesen sieht ein Nutzer dort also Text einer anderen Person.
Das ist geschlossene Zusammenarbeit an einem gemeinsamen Dokument (wie in einer
Textverarbeitung mit geteilter Datei), nicht „benutzergenerierte Inhalte“ im
Sinn der Richtlinie — die zielt auf offene, unmoderierte Inhalte, die
Auflagen zu Filter, Melden und Blockieren nach sich zieht (Richtlinie 1.2).

Fragt der Fragebogen ausdrücklich „Können Nutzer Inhalte sehen, die andere
Nutzer erstellt haben?“, ist die ehrliche Antwort trotzdem **ja, aber nur
innerhalb eines Buchs, zu dem das Konto eingeladen wurde**. Falls Apple
deswegen nachfasst, ist genau das die Antwort — nicht ein Dementi.

## Falls eine Frage zu KI auftaucht

Die App bietet KI-gestützte Wortvorschläge (Synonyme) und ein Lektorat der
offenen Seite. Beides arbeitet **ausschliesslich auf dem Text des Nutzers**,
gibt Wortlisten bzw. Beanstandungen zurück und ist kein offener Chatbot: es
gibt keine freie Eingabeaufforderung und keine Unterhaltung mit einem Modell.
Die Verarbeitung läuft über den Server, den der Nutzer einträgt (Details in der
Datenschutzerklärung, Abschnitt „KI-Verarbeitung der Inhalte“).
