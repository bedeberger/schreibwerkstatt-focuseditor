# App-Privacy-Deklaration (App Store Connect → App-Datenschutz)

Antworten für den Fragebogen, hergeleitet aus dem tatsächlichen Netzverkehr des
Clients. Grundlage ist die Regel aus [CLAUDE.md](../CLAUDE.md): Netzwerk macht
ausschliesslich der Swift-Kern, die WebView lädt nur den lokalen Cache. Alle
Aufrufe gehen an **genau einen** Server — den, den der Nutzer selbst einträgt.

**Tracking-Frage (die erste im Fragebogen): Nein.** Weder die App noch ein
Partner verknüpft Daten mit Daten Dritter zu Werbe-/Messzwecken. Kein
Werbe-SDK, kein Analyse-SDK, keine IDFA-Abfrage. Einziges Drittanbieter-Paket
im Store-Build ist GRDB (lokales SQLite, ohne Netzverkehr) — Sparkle ist im
MAS-Target nicht gelinkt.

## Erhobene Datentypen

Für alle drei gilt: **mit der Identität verknüpft = Ja**, **Tracking = Nein**,
**Zweck = App-Funktionalität** (nicht Analyse, nicht Personalisierung, nicht
Werbung).

| Kategorie | Datentyp | Was konkret |
|---|---|---|
| Benutzerinhalte | Andere Benutzerinhalte | Der geschriebene Text. Seiten-HTML im Sync (`PUT /content/pages/:id`, `GET …/sync`), dazu Textausschnitte an Rechtschreibprüfung (`POST /languagetool/check`), Wörterbuch (`POST /dictionary`), Synonyme (`GET /openthesaurus/synonyms`, `POST /jobs/synonym`) und Lektorat (`POST /jobs/check`). |
| Kennungen | Benutzer-ID | Das Gerätetoken (Bearer `swd_…`) identifiziert das Konto bei jedem Request. Server-seitig nur als SHA256-Hash gespeichert. |
| Nutzungsdaten | Produktinteraktion | Schreibzeit-Heartbeat `POST /history/writing-time` mit `{ book_id, seconds }` — speist die Schreibstatistik des Kontos. |

**Zur Produktinteraktion:** Es geht um eine nutzersichtbare Funktion
(Schreibzeit-Statistik), nicht um Verhaltensmessung. Sie lässt sich trotzdem
nicht als „nicht erhoben“ deklarieren, weil Sekunden pro Buch das Gerät
verlassen. Live-Wortzahl und Tages-Delta bleiben dagegen lokal
(`WritingStatsStore`) und sind hier nicht zu deklarieren.

## Bewusst NICHT deklariert — mit Begründung

| Kategorie | Warum nein |
|---|---|
| Kontaktdaten → E-Mail-Adresse | Das Konto entsteht **auf der Website**, nicht in der App. Die App fragt nie eine E-Mail ab und sendet nie eine; angemeldet wird mit einem eingefügten Token. Der einzige E-Mail-Bezug ist ein **eingehendes** Feld im 409-Konflikt (`server_editor_email`) — empfangen, nicht erhoben. Wer maximal defensiv deklarieren will, kann „E-Mail-Adresse, verknüpft, App-Funktionalität“ ergänzen; falsch wäre es nicht, nötig ist es nach Apples Definition nicht. |
| Diagnose (Absturz-/Leistungsdaten) | Kein Crash-Reporter, kein Telemetrie-SDK. Diagnose läuft über `os_log` und bleibt auf dem Gerät. |
| Kennungen → Geräte-ID | Kein IDFA/IDFV, keine Hardware-Kennung wird gesendet. Das „Gerätetoken“ ist eine Konto-Kennung, keine Gerätekennung — deshalb steht es oben unter Benutzer-ID. |
| Browser-/Suchverlauf | Die WebView lädt ausschliesslich `swk-app://` aus dem lokalen Cache. Angeklickte externe Links werden an den Standard-Browser übergeben, ohne dass die App sie protokolliert. |
| Standort, Kontakte, Gesundheit, Finanzen, Käufe, sensible Daten | Werden nirgends abgefragt. Keine In-App-Käufe. |

## Was der Deklaration widerspräche (bei künftigen Änderungen prüfen)

- Ein Crash-/Analyse-SDK einbauen → Diagnose-Kategorie wird fällig.
- Direktaufrufe der WebView ans Netz zulassen → die Aussage „nur der Swift-Kern
  spricht mit dem Server“ trägt nicht mehr.
- Ein zweiter, fest verdrahteter Endpunkt (Telemetrie, Update-Ping) → „genau ein
  vom Nutzer gewählter Server“ stimmt nicht mehr. Sparkle im DMG-Kanal ist
  genau deshalb im Store-Build nicht enthalten.

## Anschluss-Punkt: Kontolöschung in der App

Richtlinie 5.1.1(v) verlangt, dass ein Konto **in der App** gelöscht werden
kann, wenn die App eine Kontoerstellung unterstützt. Die Datenschutzerklärung
verweist auf eine formlose E-Mail — das genügt Apple in der Regel nicht.
Aktueller Stand des Punktes: [SIGNING.md](../SIGNING.md) („App Store“,
„Noch offen“). Er ist unabhängig von dieser Deklaration zu lösen und ohne
Lösung der wahrscheinlichste Reject-Grund der ersten Einreichung.

Entlastend, aber nicht sicher tragend: Die App **erstellt** kein Konto — sie
nimmt nur ein Token entgegen, das im Web ausgestellt wurde. Das ist gegenüber
dem Review argumentierbar (siehe [REVIEW-NOTES.md](../REVIEW-NOTES.md)), die
Entscheidung liegt aber beim Prüfer.
