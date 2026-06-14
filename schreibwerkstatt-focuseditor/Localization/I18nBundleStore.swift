//
//  I18nBundleStore.swift
//  schreibwerkstatt-focuseditor
//
//  OTA-Lader für die Oberflächen-Strings (Namespace `macclient.*`). Analog zum
//  EditorBundleStore, aber schlanker: kein ZIP, sondern eine kleine JSON-Datei.
//
//    GET /content/macclient-i18n.json  → { "de": { key: value, … }, "en": { … } }
//
//  Der Override wird ETag-getrieben gezogen und nach `L10nStore.otaCacheURL`
//  gecacht. Wie das Editor-Bundle greift ein frischer Stand erst beim NÄCHSTEN
//  Start (der L10nStore liest den Cache in seinem init) — kein Hot-Swap der
//  laufenden UI.
//
//  Offline-Kern: Schlägt der Download fehl (offline) oder liefert der Server
//  `404` (Endpoint noch nicht ausgerollt / serverseitig aus), bleibt es still
//  beim gebündelten Stand (mac-de/mac-en im App-Bundle). Kein Fehlerzustand.
//

import Foundation

@MainActor
final class I18nBundleStore {
    private let api: APIClient
    private let fileManager = FileManager.default
    private let bundlePath = "/content/macclient-i18n.json"
    private let cacheURL = L10nStore.otaCacheURL
    private let metaURL: URL

    private var isRefreshing = false

    init(api: APIClient) {
        self.api = api
        self.metaURL = cacheURL.deletingLastPathComponent()
            .appendingPathComponent("i18n-cache.meta.json")
    }

    /// Zieht den String-Override konditional (ETag). Still: ein vorhandener Cache
    /// bleibt bei Fehlern/`404` unangetastet, kein Fehlerzustand. Nur als
    /// Hintergrund-Refresh gedacht (greift beim nächsten Start).
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let res = try await api.getRaw(bundlePath, ifNoneMatch: loadETag())
            if res.notModified { return }
            // Vor dem Schreiben validieren — nur wohlgeformtes JSON cachen.
            guard (try? JSONSerialization.jsonObject(with: res.data) as? [String: [String: String]]) != nil else {
                return
            }
            try? fileManager.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
            try res.data.write(to: cacheURL, options: .atomic)
            saveETag(res.etag)
            // Den laufenden Store sofort nachladen — schadet nicht, auch wenn die
            // sichtbare Wirkung praktisch erst beim nächsten Start greift.
            L10nStore.shared.loadOTAFromCache()
        } catch {
            // Offline / 404 / sonstiger Fehler → gebündelter Stand bleibt gültig.
        }
    }

    // MARK: - ETag-Sidecar

    private struct Meta: Codable { let etag: String? }

    private func loadETag() -> String? {
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(Meta.self, from: data) else { return nil }
        return meta.etag
    }

    private func saveETag(_ etag: String?) {
        guard let data = try? JSONEncoder().encode(Meta(etag: etag)) else { return }
        try? data.write(to: metaURL, options: .atomic)
    }
}
