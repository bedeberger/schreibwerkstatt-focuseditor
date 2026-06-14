//
//  EditorBundleStore.swift
//  schreibwerkstatt-focuseditor
//
//  OTA-Verwaltung des Focus-Editor-Bundles. Statt die Editor-Assets zur
//  Build-Zeit aus dem Hauptrepo zu kopieren, zieht der Client sie zur Laufzeit
//  vom Server (GET /content/editor-bundle.zip) und cacht sie lokal:
//
//    Application Support/schreibwerkstatt-focuseditor/web-cache/   (js/, css/, index.html)
//    …/web-cache.meta.json                                         (ETag + sourceCommit)
//
//  HARTE REGEL (CLAUDE.md): Die WebView lädt IMMER lokal — sie liest nur aus
//  diesem Cache (via AppSchemeHandler). Netzwerk macht ausschließlich der
//  Swift-Kern. Offline-Kern bleibt gewahrt: nach dem ersten erfolgreichen
//  Download arbeitet die App vollständig offline; ein Refresh greift still beim
//  nächsten Start (kein Hot-Swap mitten im Schreiben → Datenverlust-Schutz).
//
//  Das ZIP ist DEFLATE-komprimiert und wird mit MiniZip (bordeigen, sandbox-
//  tauglich) entpackt. Das `index.html` (Boot/Bridge) ist NICHT im Bundle —
//  der Client schreibt es aus WebAssets + den Manifest-`cssFiles`.
//

import Foundation
import Combine

@MainActor
final class EditorBundleStore: ObservableObject {

    enum BundleState: Equatable {
        case idle          // noch nichts versucht
        case refreshing    // Download/Entpacken läuft (nur relevant ohne Cache)
        case ready         // ein nutzbares Bundle liegt im Cache
        case failed(String) // kein Cache UND Download fehlgeschlagen
    }

    @Published private(set) var state: BundleState = .idle

    private let api: APIClient
    private let fileManager = FileManager.default
    private let cacheDir: URL
    private let metaURL: URL
    private let bundlePath = "/content/editor-bundle.zip"

    /// Verhindert parallele Refreshes (mehrfaches `ensureReady` aus der View).
    private var isRefreshing = false

    init(api: APIClient) {
        self.api = api
        let base = (try? fileManager.url(for: .applicationSupportDirectory,
                                         in: .userDomainMask,
                                         appropriateFor: nil,
                                         create: true))
            ?? fileManager.temporaryDirectory
        let dir = base.appendingPathComponent("schreibwerkstatt-focuseditor", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        self.cacheDir = dir.appendingPathComponent("web-cache", isDirectory: true)
        self.metaURL = dir.appendingPathComponent("web-cache.meta.json")
        if hasCache { state = .ready }
    }

    /// Wurzelverzeichnis, das der AppSchemeHandler ausliefert.
    var webRoot: URL { cacheDir }

    /// Liegt ein bootfähiges Bundle vor? (index.html als Marker.)
    var hasCache: Bool {
        fileManager.fileExists(atPath: cacheDir.appendingPathComponent("index.html").path)
    }

    // MARK: - Steuerung

    /// Aus der Editor-Host-View (nur bei signedIn). Mit Cache: sofort bereit,
    /// Refresh still im Hintergrund (greift beim nächsten Start). Ohne Cache:
    /// blockierender Erst-Download, dessen Zustand die UI treibt.
    func ensureReady() async {
        if hasCache {
            state = .ready
            Task { await refresh(silent: true) }   // Hintergrund-Update für den nächsten Start
        } else {
            await refresh(silent: false)
        }
    }

    /// Lädt das Bundle konditional (ETag) und tauscht den Cache atomar.
    /// `silent`: ein vorhandener Cache bleibt bei Fehlern unangetastet und der
    /// Zustand fällt nicht auf `.failed` (Hintergrund-Refresh).
    func refresh(silent: Bool) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        if !silent && !hasCache { state = .refreshing }

        do {
            let res = try await api.getRaw(bundlePath, ifNoneMatch: loadMeta()?.etag)

            if res.notModified {
                state = hasCache ? .ready : .failed("Server meldet 304, aber kein lokaler Cache.")
                return
            }

            try installBundle(zip: res.data, etag: res.etag)
            state = .ready
        } catch {
            if hasCache {
                state = .ready   // Offline/Fehler: am vorhandenen Bundle festhalten
            } else if !silent {
                state = .failed(Self.describe(error))
            }
        }
    }

    // MARK: - Installation

    /// Entpackt das ZIP in ein Staging-Verzeichnis, schreibt index.html aus dem
    /// Manifest und tauscht den Live-Cache atomar.
    private func installBundle(zip: Data, etag: String?) throws {
        let entries = try MiniZip.entries(in: zip)
        guard !entries.isEmpty else { throw MiniZipError.malformed("leeres Bundle") }

        // Staging neben dem Cache (gleicher Volume → atomarer Replace möglich).
        let staging = cacheDir.deletingLastPathComponent()
            .appendingPathComponent("web-cache.staging-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        var manifest: BundleManifest?
        for entry in entries {
            // Path-Traversal-Schutz: nur Pfade innerhalb des Stagings.
            let dst = staging.appendingPathComponent(entry.path).standardizedFileURL
            guard dst.path == staging.path || dst.path.hasPrefix(staging.path + "/") else {
                throw MiniZipError.malformed("Pfad-Ausbruch: \(entry.path)")
            }
            if entry.path == "bundle-manifest.json" {
                manifest = try? JSONDecoder().decode(BundleManifest.self, from: entry.data)
            }
            try fileManager.createDirectory(at: dst.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try entry.data.write(to: dst)
        }

        // Client-eigenes index.html (Boot/Bridge) aus dem Manifest erzeugen.
        let css = manifest?.cssFiles ?? []
        let commit = manifest?.sourceCommit ?? "unknown"
        let html = WebAssets.indexHTML(cssFiles: css, sourceCommit: commit)
        try Data(html.utf8).write(to: staging.appendingPathComponent("index.html"))

        try swapIntoPlace(staging: staging)
        saveMeta(BundleMeta(etag: etag, sourceCommit: commit))
    }

    /// Ersetzt den Live-Cache atomar durch das Staging-Verzeichnis.
    private func swapIntoPlace(staging: URL) throws {
        if fileManager.fileExists(atPath: cacheDir.path) {
            _ = try fileManager.replaceItemAt(cacheDir, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: cacheDir)
        }
    }

    // MARK: - Meta (ETag/Commit)

    private struct BundleManifest: Decodable {
        let sourceCommit: String?
        let jsFiles: [String]?
        let cssFiles: [String]?
    }

    private struct BundleMeta: Codable {
        let etag: String?
        let sourceCommit: String?
    }

    private func loadMeta() -> BundleMeta? {
        guard hasCache, let data = try? Data(contentsOf: metaURL) else { return nil }
        return try? JSONDecoder().decode(BundleMeta.self, from: data)
    }

    private func saveMeta(_ meta: BundleMeta) {
        guard let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: metaURL, options: .atomic)
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
