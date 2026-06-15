//
//  SourceFileSizeTests.swift
//  schreibwerkstatt-focuseditorTests
//
//  Wartbarkeits-Guard: hält die Swift-Quelldateien unter einer harten
//  Zeilen-Obergrenze. Große Dateien sind schwerer zu lesen, zu reviewen und
//  (für Claude Code) zu editieren — eine Datei = möglichst eine Verantwortung.
//  Wächst eine Datei über das Limit, ist das ein Signal zum Aufteilen (in Swift
//  meist per `extension` über mehrere Dateien, siehe `SyncEngine[+Push/+Pull]`).
//
//  Der Test läuft rein lokal über das Dateisystem (kein Server, keine App-
//  Symbole). Die Source-Wurzel wird über `#filePath` der Testdatei ermittelt.
//

import XCTest

final class SourceFileSizeTests: XCTestCase {

    /// Harte Obergrenze. Über diesem Wert schlägt der Test fehl → aufteilen oder
    /// (mit Begründung) in `allowedOverLimit` aufnehmen. Richtwert/Ziel sind eher
    /// 300–500 Zeilen; 800 ist die diskutierte Schmerzgrenze.
    private let maxLines = 800

    /// Bewusst geduldete Ausnahmen: Dateiname → Begründung. Diese dürfen das
    /// Limit überschreiten (der zweite Test wacht darüber, dass ein Eintrag
    /// wieder verschwindet, sobald die Datei unters Limit fällt).
    private let allowedOverLimit: [String: String] = [
        "WebAssets.swift": "Ein zusammenhängendes HTML/JS-Boot-Template (Client-Glue) — kein sinnvoller Schnitt; gehört bewusst in eine Datei.",
    ]

    func testSwiftSourceFilesStayUnderLineLimit() throws {
        let sourceDir = try Self.sourceRoot()
        let files = try Self.swiftFiles(in: sourceDir)
        XCTAssertFalse(files.isEmpty, "keine Swift-Quelldateien gefunden unter \(sourceDir.path)")

        var offenders: [String] = []
        for file in files {
            let name = file.lastPathComponent
            let lines = try Self.lineCount(of: file)
            if lines > maxLines && allowedOverLimit[name] == nil {
                offenders.append("  \(name): \(lines) Zeilen (Limit \(maxLines))")
            }
        }

        XCTAssertTrue(offenders.isEmpty, """
            \(offenders.count) Datei(en) über dem Zeilen-Limit — aufteilen \
            (z. B. per `extension`) oder mit Begründung in `allowedOverLimit` aufnehmen:
            \(offenders.sorted().joined(separator: "\n"))
            """)
    }

    /// Hält die Allowlist sauber: eine geduldete Datei, die wieder unters Limit
    /// gefallen ist, soll ihren Eintrag verlieren (sonst verwässert der Guard).
    func testAllowlistHasNoStaleEntries() throws {
        let sourceDir = try Self.sourceRoot()
        let byName = Dictionary(uniqueKeysWithValues:
            try Self.swiftFiles(in: sourceDir).map { ($0.lastPathComponent, $0) })

        for (name, reason) in allowedOverLimit {
            guard let url = byName[name] else {
                XCTFail("Allowlist-Eintrag '\(name)' (\(reason)) zeigt auf keine existierende Datei")
                continue
            }
            let lines = try Self.lineCount(of: url)
            XCTAssertGreaterThan(lines, maxLines,
                "'\(name)' liegt mit \(lines) Zeilen wieder unter dem Limit (\(maxLines)) — Allowlist-Eintrag entfernen")
        }
    }

    // MARK: - Helpers

    /// Source-Wurzel relativ zu dieser Testdatei: `…/<repo>/schreibwerkstatt-focuseditorTests/…`
    /// → zwei Ebenen hoch ist das Repo, darunter der App-Sources-Ordner.
    private static func sourceRoot() throws -> URL {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // schreibwerkstatt-focuseditorTests/
            .deletingLastPathComponent()   // <repo>/
        let dir = repoRoot.appendingPathComponent("schreibwerkstatt-focuseditor", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            throw XCTSkip("Source-Ordner nicht am erwarteten Pfad (\(dir.path)) — andere Maschine/CI?")
        }
        return dir
    }

    private static func swiftFiles(in dir: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// Zählt Zeilenumbrüche — deckt sich mit `wc -l`.
    private static func lineCount(of url: URL) throws -> Int {
        let content = try String(contentsOf: url, encoding: .utf8)
        return content.lazy.filter { $0 == "\n" }.count
    }
}
