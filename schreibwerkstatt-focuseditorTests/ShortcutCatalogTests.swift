//
//  ShortcutCatalogTests.swift
//  schreibwerkstatt-focuseditorTests
//
//  Guard für die harte Regel „Tastaturkürzel-Hilfe pflegen" (CLAUDE.md). Die
//  Regel war bis zur Einführung von [Shortcuts.swift](../schreibwerkstatt-focuseditor/Shortcuts.swift)
//  reine Disziplin — und ist auseinandergelaufen: ⌘N und ⌘⇧R fehlten in der
//  Hilfe, und das Menü „Buch exportieren" hatte ⌘⇧E belegt, obwohl der Editor
//  damit den Fokus-Modus umschaltet. Ein Menü-Kürzel greift VOR der WKWebView,
//  der Fokus-Umschalter war also tot, während die Hilfe ihn weiter bewarb.
//
//  Vier Zusagen:
//    1. Kein Kürzel wird am Katalog vorbei deklariert (Quelltext-Scan).
//    2. Ein nativer Menübefehl verdeckt kein Editor-/Picker-Kürzel.
//    3. Keine zwei nativen Befehle teilen sich eine Taste.
//    4. Jede Beschreibung existiert in BEIDEN i18n-Katalogen.
//
//  Zusage 1 läuft über den Quelltext (wie `LocalizationCatalogTests`), weil
//  genau der Bypass geprüft wird, den ein Typ-Test nicht sehen kann.
//

import XCTest
import SwiftUI

final class ShortcutCatalogTests: XCTestCase {

    // MARK: - 1. Kein Kürzel am Katalog vorbei

    /// Erlaubt bleibt `.keyboardShortcut(.cancelAction/.defaultAction)`: das sind
    /// Rollen innerhalb eines Sheets (⏎/⎋ im Dialog), keine app-weiten Kürzel —
    /// sie stehen darum bewusst nicht im Katalog.
    func testNoShortcutIsDeclaredOutsideTheCatalog() throws {
        let root = try Self.sourceRoot()
        var offenders: [String] = []

        for file in try Self.swiftFiles(in: root) where file.lastPathComponent != "Shortcuts.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in text.components(separatedBy: .newlines).enumerated() {
                guard line.contains(".keyboardShortcut(") else { continue }
                let ok = line.contains(".keyboardShortcut(Shortcuts.")
                    || line.contains(".cancelAction")
                    || line.contains(".defaultAction")
                guard !ok else { continue }
                offenders.append("  \(file.lastPathComponent):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }

        XCTAssertTrue(offenders.isEmpty, """
            \(offenders.count) Kürzel am Katalog vorbei deklariert — in \
            Shortcuts.swift eintragen und über `.keyboardShortcut(Shortcuts.…)` binden \
            (sonst fehlt es in der Hilfe und kann ein Editor-Kürzel verdecken):
            \(offenders.joined(separator: "\n"))
            """)
    }

    // MARK: - 2. Native Befehle verdecken nichts

    /// Ein nativer Menübefehl fängt die Taste app-weit ab, bevor die WebView sie
    /// sieht. Trägt ein `.editor`- oder `.picker`-Eintrag dieselbe Taste, ist er
    /// damit unerreichbar — und die Hilfe bewirbt eine Funktion, die es nicht
    /// mehr gibt. Genau dieser Fall (⌘⇧E: Buch-Export vs. Fokus-Umschalter) war
    /// der Anlass für den Katalog.
    func testNativeShortcutsDoNotShadowOthers() {
        let natives = Shortcuts.all.filter { $0.owner == .native }
        var offenders: [String] = []

        for native in natives {
            for other in Shortcuts.all where other.id != native.id && other.chord == native.chord {
                guard other.owner != .native else { continue }   // Fall 3 meldet das
                offenders.append("  \(native.chord): '\(native.id)' (nativ) verdeckt '\(other.id)' (\(other.owner))")
            }
        }

        XCTAssertTrue(offenders.isEmpty, """
            \(offenders.count) Kollision(en) — ein Menü-Kürzel nimmt dem Editor/Picker die Taste weg:
            \(offenders.joined(separator: "\n"))
            """)
    }

    // MARK: - 3. Native Befehle untereinander eindeutig

    func testNativeShortcutsAreUnique() {
        let natives = Shortcuts.all.filter { $0.owner == .native }
        let grouped = Dictionary(grouping: natives, by: \.chord).filter { $0.value.count > 1 }
        let offenders = grouped
            .map { "  \($0.key): \($0.value.map(\.id).sorted().joined(separator: ", "))" }
            .sorted()

        XCTAssertTrue(offenders.isEmpty, """
            \(offenders.count) doppelt belegte(s) Menü-Kürzel:
            \(offenders.joined(separator: "\n"))
            """)
    }

    // MARK: - 4. Beschreibungen sind übersetzt

    func testEveryShortcutLabelExistsInBothCatalogs() throws {
        let de = try Self.catalog("de"), en = try Self.catalog("en")
        var offenders: [String] = []

        for spec in Shortcuts.all {
            if de[spec.labelKey] == nil { offenders.append("  \(spec.id): '\(spec.labelKey)' fehlt in mac-de.json") }
            if en[spec.labelKey] == nil { offenders.append("  \(spec.id): '\(spec.labelKey)' fehlt in mac-en.json") }
        }
        for section in ShortcutSection.allCases {
            if de[section.titleKey] == nil { offenders.append("  '\(section.titleKey)' fehlt in mac-de.json") }
            if en[section.titleKey] == nil { offenders.append("  '\(section.titleKey)' fehlt in mac-en.json") }
        }

        XCTAssertTrue(offenders.isEmpty, offenders.joined(separator: "\n"))
    }

    // MARK: - 5. Anzeige-Glyphen

    /// Die Capsules in der Hilfe werden aus `key`/`modifiers` abgeleitet — hier
    /// festgenagelt, damit ein Umbau der Ableitung nicht still ⌃⌘F zu „F⌘⌃" macht.
    ///
    /// Reihenfolge ist die von macOS (⌃ ⌥ ⇧ ⌘), nicht die der früheren
    /// handgeschriebenen Liste: das System zeigt „⇧⌘R", nicht „⌘⇧R". Die Hilfe
    /// liest sich damit wie die Menüleiste daneben.
    func testGlyphsFollowMacOSOrder() {
        XCTAssertEqual(Shortcuts.fullscreen.glyphs, ["⌃", "⌘", "F"])
        XCTAssertEqual(Shortcuts.revisions.glyphs, ["⇧", "⌘", "R"])
        XCTAssertEqual(Shortcuts.openSettings.glyphs, ["⌘", ","])
        XCTAssertEqual(Shortcuts.pickerOpenFirst.glyphs, ["⏎"])
        XCTAssertEqual(Shortcuts.pickerClose.glyphs, ["⎋"])
    }

    /// Jeder Eintrag steht in genau einem Abschnitt und `all` ist vollständig —
    /// ein vergessener Eintrag in `all` fehlt sonst still in der Hilfe.
    func testSectionsPartitionTheCatalog() {
        let fromSections = ShortcutSection.allCases.flatMap(Shortcuts.inSection).map(\.id)
        XCTAssertEqual(Set(fromSections), Set(Shortcuts.all.map(\.id)))
        XCTAssertEqual(fromSections.count, Shortcuts.all.count, "ein Eintrag steht mehrfach in `all`")
        XCTAssertEqual(Set(Shortcuts.all.map(\.id)).count, Shortcuts.all.count, "doppelte id im Katalog")
    }

    // MARK: - Hilfen

    private static func sourceRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("schreibwerkstatt-focuseditor")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Shortcuts.swift").path,
                                              isDirectory: &isDir) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("App-Quellordner nicht gefunden")
    }

    private static func swiftFiles(in dir: URL) throws -> [URL] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    private static func catalog(_ locale: String) throws -> [String: String] {
        let url = try sourceRoot()
            .appendingPathComponent("Localization")
            .appendingPathComponent("mac-\(locale).json")
        let data = try Data(contentsOf: url)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw XCTSkip("mac-\(locale).json nicht lesbar")
        }
        return dict
    }
}
