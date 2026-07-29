//
//  LektoratJobStore.swift
//  schreibwerkstatt-focuseditor
//
//  Startet das serverseitige Seiten-Lektorat für die offene Seite
//  (`POST /jobs/check`) und pollt den Job bis zum Ende (`GET /jobs/:id`) —
//  wie der KI-Synonym-Pfad kapselt der Swift-Kern das Polling, die UI sieht
//  nur einen Zustand. Ergebnisse (Beanstandungen) leben serverseitig und
//  werden in der Web-App gelesen; hier zeigt der Client nur, dass der Lauf
//  fertig ist und wie viele Beanstandungen er fand.
//
//  WICHTIG — der Job lektoriert den SERVER-Stand der Seite. Vor dem Anlegen
//  wird darum der offene Draft gesichert und gepusht (`prepare`, in `AppCore`
//  auf `flushDraftSave` + `syncNow` verdrahtet), sonst prüft der Server einen
//  veralteten Text.
//
//  Netzwerk macht ausschliesslich der Swift-Kern (HARTE REGEL) — kein
//  Bridge-Op, die WebView ist an diesem Feature nicht beteiligt.
//

import Foundation
import Combine
import OSLog

@MainActor
final class LektoratJobStore: ObservableObject {

    /// Zustand EINES Lektorats-Laufs. `preparing` = Draft sichern + Push,
    /// `running` = Server-Job läuft (Fortschritt 0…1), `done`/`failed` = Banner.
    enum Phase: Equatable {
        case idle
        case preparing
        case running(progress: Double)
        case done(count: Int)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Seite/Buch des laufenden bzw. letzten Laufs — trägt den Banner-Text und
    /// den Deep-Link in die Web-App (dort stehen die Beanstandungen).
    @Published private(set) var pageId: Int?
    @Published private(set) var bookId: Int?
    @Published private(set) var pageName: String?

    /// Läuft gerade ein Lauf? (Knopf zeigt dann Spinner + „Abbrechen".)
    var isBusy: Bool {
        switch phase {
        case .preparing, .running: return true
        case .idle, .done, .failed: return false
        }
    }

    /// Fortschritt in Prozent (für den Tooltip); `nil` solange nur vorbereitet wird.
    var progressPercent: Int? {
        guard case .running(let p) = phase else { return nil }
        return Int((p * 100).rounded())
    }

    /// Deep-Link auf die geprüfte Seite in der Web-App (`#book/:id/page/:id`) —
    /// dort zeigt die Lektorats-Karte die Beanstandungen. `nil`, solange Buch
    /// oder Seite fehlen.
    var resultWebURL: URL? {
        guard let pageId, let bookId else { return nil }
        return ServerConfig.pageURL(onServer: ServerConfig.baseURLString,
                                    fragment: "book/\(bookId)/page/\(pageId)")
    }

    /// Poll-Kadenz + Deckel: Ein Seiten-Lektorat ist ein KI-Lauf (bei Cache-HIT
    /// sofort, sonst je nach Provider bis zu Minuten) → 1,5 s × 240 ≈ 6 Minuten,
    /// danach gilt der Job als hängend (der Server läuft ggf. weiter, wir hören
    /// nur auf zu warten).
    private static let pollInterval = Duration.milliseconds(1500)
    private static let maxPolls = 240

    private let api: APIClient?
    /// Sichert den offenen Draft und pusht ihn (local-first bleibt local-first —
    /// erst lokal, dann Server). Injiziert, damit der Store weder Bridge noch
    /// SyncEngine kennt (und in Tests ohne beides läuft).
    private let prepare: () async -> Void
    private var runTask: Task<Void, Never>?
    /// Job-ID des laufenden Server-Jobs (für „Abbrechen" via `DELETE /jobs/:id`).
    private var activeJobId: String?
    private let log = Logger(subsystem: "ch.schreibwerkstatt.focuseditor", category: "lektorat")

    init(api: APIClient?, prepare: @escaping () async -> Void = {}) {
        self.api = api
        self.prepare = prepare
    }

    // MARK: - Steuerung

    /// Startet das Lektorat für eine Seite. No-op, solange schon ein Lauf läuft
    /// (der Server dedupliziert zwar selbst — `findActiveJobId` — aber die UI
    /// soll gar nicht erst zwei Läufe suggerieren).
    func start(pageId: Int, bookId: Int?, pageName: String?) {
        guard !isBusy else { return }
        self.pageId = pageId
        self.bookId = bookId
        self.pageName = pageName
        phase = .preparing
        runTask = Task { [weak self] in
            await self?.run(pageId: pageId, bookId: bookId, pageName: pageName)
            self?.runTask = nil
        }
    }

    /// Bricht den laufenden Lauf ab: Poll-Task beenden und den Server-Job
    /// stornieren (`DELETE /jobs/:id`, best-effort — ein bereits fertiger Job
    /// antwortet mit 400 und darf still scheitern).
    func cancel() {
        runTask?.cancel()
        runTask = nil
        if let jobId = activeJobId, let api {
            let encoded = Self.encodePath(jobId)
            Task { try? await api.sendVoid("/jobs/\(encoded)", method: .DELETE) }
        }
        activeJobId = nil
        phase = .idle
    }

    /// Ergebnis-/Fehler-Banner schliessen (Nutzeraktion). Wirkt nur auf die
    /// terminalen Zustände — ein laufender Lauf wird davon nicht angetastet.
    func dismiss() {
        switch phase {
        case .done, .failed: phase = .idle
        case .idle, .preparing, .running: break
        }
    }

    /// Server-Wechsel/Abmelden: transienten Zustand verwerfen (die Job-ID und
    /// der Deep-Link gelten nur am alten Server).
    func reset() {
        runTask?.cancel()
        runTask = nil
        activeJobId = nil
        pageId = nil
        bookId = nil
        pageName = nil
        phase = .idle
    }

    // MARK: - Ablauf

    private func run(pageId: Int, bookId: Int?, pageName: String?) async {
        guard let api else {
            phase = .failed(t("lektorat.err.offline"))
            return
        }
        // Erst den Tippstand sichern + pushen, sonst lektoriert der Server einen
        // veralteten Text. Bleibt der Push liegen (offline), läuft der Job auf
        // dem letzten Server-Stand — der Banner nennt dann trotzdem ein Ergebnis,
        // darum wird ein fehlgeschlagener Push nicht verschluckt, sondern über
        // den Sync-Status sichtbar (dort gehört er hin).
        await prepare()
        if Task.isCancelled { phase = .idle; return }

        phase = .running(progress: 0)
        do {
            let req = CheckJobRequest(page_id: pageId, book_id: bookId, page_name: pageName)
            let created = try await api.send("/jobs/check", method: .POST, body: req,
                                             decode: CheckJobCreateResponse.self)
            guard let jobId = created.jobId else {
                phase = .failed(t("lektorat.err.generic"))
                return
            }
            activeJobId = jobId
            try await poll(jobId: jobId, api: api)
            activeJobId = nil
        } catch is CancellationError {
            activeJobId = nil
            phase = .idle
        } catch {
            activeJobId = nil
            log.error("Lektorat für Seite \(pageId, privacy: .public) fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
            phase = .failed(Self.message(for: error))
        }
    }

    /// Pollt `GET /jobs/:id`, bis der Job terminal ist. Transiente Lesefehler
    /// (Netz-Zucken) werden übersprungen statt den Lauf abzubrechen — der Job
    /// läuft serverseitig weiter; nur der Deckel beendet das Warten.
    private func poll(jobId: String, api: APIClient) async throws {
        let encoded = Self.encodePath(jobId)
        for _ in 0..<Self.maxPolls {
            try await Task.sleep(for: Self.pollInterval)
            guard let job = try? await api.send("/jobs/\(encoded)",
                                                decode: CheckJobStatusResponse.self) else {
                continue
            }
            switch job.status {
            case "queued", "running", .none:
                let pct = Double(job.progress ?? 0) / 100
                phase = .running(progress: min(max(pct, 0), 1))
            case "done":
                // `empty: true` (leere Seite) liefert kein `fehler`-Array → 0.
                phase = .done(count: job.result?.fehler?.count ?? 0)
                return
            default:   // error / cancelled
                // `job.error` ist ein i18n-Key des Server-Katalogs (nicht in den
                // mac-Katalogen) → generische Meldung zeigen, Key nur ins Log.
                if let raw = job.error {
                    log.notice("Lektorats-Job \(jobId, privacy: .public) endete mit \(raw, privacy: .public)")
                }
                phase = .failed(t("lektorat.err.generic"))
                return
            }
        }
        phase = .failed(t("lektorat.err.timeout"))
    }

    // MARK: - Hilfen

    private static func encodePath(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? raw
    }

    /// Server-/Transport-Fehler in eine Meldung übersetzen, die dem Nutzer sagt,
    /// was zu tun ist (403 = fehlende Lektorats-Rolle, 404 = Seite/Buch weg).
    private static func message(for error: Error) -> String {
        guard let authError = error as? AuthError else {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        switch authError {
        case .network:
            return t("lektorat.err.offline")
        case .server(let status, _, _) where status == 403:
            return t("lektorat.err.forbidden")
        case .server(let status, _, _) where status == 404:
            return t("lektorat.err.notFound")
        default:
            return authError.errorDescription ?? t("lektorat.err.generic")
        }
    }
}

// MARK: - Job-DTOs

/// Body für `POST /jobs/check` (Seiten-Lektorat, s. routes/jobs/lektorat.js).
/// `book_id` löst der Server notfalls selbst auf (`resolvePageBookId`),
/// `page_name` trägt nur das Job-Label in der Web-Job-Liste.
private struct CheckJobRequest: Encodable {
    let page_id: Int
    let book_id: Int?
    let page_name: String?
}

/// Antwort von `POST /jobs/check` — die Job-ID (`existing: true`, falls schon
/// ein Lauf für die Seite offen war; wird gleich behandelt: wir pollen ihn).
private struct CheckJobCreateResponse: Decodable {
    let jobId: String?
    let existing: Bool?
}

/// Antwort von `GET /jobs/:id` — Status + Fortschritt (0…100) und bei `done`
/// die Beanstandungen. Nur die Anzahl interessiert hier; die Findings selbst
/// bleiben serverseitig (gelesen wird sie in der Web-App).
private struct CheckJobStatusResponse: Decodable {
    struct Result: Decodable {
        struct Finding: Decodable {}
        let fehler: [Finding]?
    }
    let status: String?
    let progress: Int?
    let result: Result?
    let error: String?
}
