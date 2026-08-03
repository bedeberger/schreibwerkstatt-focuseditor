//
//  DistributionTargetsTests.swift
//  schreibwerkstatt-focuseditorTests
//
//  Guard für die zwei Distributionswege (CLAUDE.md „Zwei Distributionswege"):
//  ein Quellcode, zwei Targets — `schreibwerkstatt-focuseditor` (DMG, Sparkle)
//  und `Focuseditor-MAS` (App Store, ohne Sparkle). Der ganze Unterschied ist
//  Konfiguration, und Konfigurationsdrift fällt sonst erst beim nächsten
//  Store-Release auf (oder wird von Apple abgelehnt).
//
//  Geprüft wird rein statisch über das Dateisystem (kein Build, kein Server):
//  die zwei Info-Plists und die Projektdatei. Die `project.pbxproj` ist ein
//  OpenStep-Plist und lässt sich darum mit `PropertyListSerialization` als
//  Objekt-Graph lesen — der Test hängt an Target-NAMEN, nicht an UUIDs.
//

import XCTest

final class DistributionTargetsTests: XCTestCase {

    /// Target-Namen wie in Xcode.
    private let dmgTarget = "schreibwerkstatt-focuseditor"
    private let masTarget = "Focuseditor-MAS"

    /// Die einzigen Schlüssel, die es nur im DMG-Plist geben darf. Ein eigener
    /// Update-Mechanismus ist im App Store verboten (`SU*` = Sparkle).
    private let sparkleOnlyKeys: Set<String> = [
        "SUFeedURL",
        "SUPublicEDKey",
        "SUEnableInstallerLauncherService",
        "SUEnableAutomaticChecks",
    ]

    // MARK: - Info-Plist-Parität

    /// Kein `SU*`-Key im Store-Bundle — ein Sparkle-Artefakt dort ist ein
    /// Ablehnungsgrund (und `archive-mas.sh` prüft es erst beim Release).
    func testStorePlistHasNoSparkleKeys() throws {
        let mas = try plist(named: "Info-MAS.plist")
        let strays = mas.keys.filter { $0.hasPrefix("SU") }.sorted()
        XCTAssertTrue(strays.isEmpty,
            "Config/Info-MAS.plist enthält Sparkle-Keys \(strays) — im App Store verboten")
    }

    /// Beide Plists dürfen sich **ausschließlich** um die `SU*`-Keys
    /// unterscheiden. Fängt den typischen Fehler: neuer Schlüssel (URL-Schema,
    /// Usage-Description, Demo-Zugang …) nur in eine der beiden Dateien
    /// geschrieben — der andere Kanal verliert die Funktion still.
    func testPlistsDifferOnlyBySparkleKeys() throws {
        let dmg = try plist(named: "Info.plist")
        let mas = try plist(named: "Info-MAS.plist")

        let onlyInDmg = Set(dmg.keys).subtracting(mas.keys)
        XCTAssertEqual(onlyInDmg, sparkleOnlyKeys, """
            Schlüssel nur in Config/Info.plist: \(onlyInDmg.sorted()) — \
            erwartet nur die Sparkle-Keys. Neue Schlüssel IMMER auch in \
            Config/Info-MAS.plist ergänzen (oder, wenn sie wirklich nur zum \
            DMG-Weg gehören, hier in `sparkleOnlyKeys` aufnehmen).
            """)

        let onlyInMas = Set(mas.keys).subtracting(dmg.keys)
        XCTAssertTrue(onlyInMas.isEmpty,
            "Schlüssel nur in Config/Info-MAS.plist: \(onlyInMas.sorted()) — auch in Config/Info.plist ergänzen")

        for key in Set(dmg.keys).intersection(mas.keys).sorted() {
            let a = dmg[key] as AnyObject, b = mas[key] as AnyObject
            XCTAssertTrue(a.isEqual(b),
                "Schlüssel '\(key)' hat in den beiden Plists verschiedene Werte (\(a) vs. \(b))")
        }
    }

    // MARK: - Target-Konfiguration (project.pbxproj)

    /// Das Store-Target darf Sparkle weder linken noch kompilieren, und es darf
    /// keine Entitlements-Datei setzen (die `mach-lookup`-Exception für Sparkles
    /// Installer-XPC wird für App-Store-Profile nicht erteilt — die Validierung
    /// scheitert). Sandbox + Netzwerk kommen dort aus den `ENABLE_*`-Settings.
    func testStoreTargetHasNoSparkleAndNoEntitlements() throws {
        let project = try Xcodeproj()
        let target = try project.nativeTarget(named: masTarget)

        XCTAssertFalse(target.packageProducts.contains("Sparkle"),
            "\(masTarget) linkt Sparkle — im App Store verboten")

        for config in target.configurations {
            let settings = config.settings
            let conditions = settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] as? String ?? ""
            XCTAssertFalse(conditions.contains("SPARKLE"),
                "\(masTarget)/\(config.name): SWIFT_ACTIVE_COMPILATION_CONDITIONS enthält SPARKLE")
            XCTAssertNil(settings["CODE_SIGN_ENTITLEMENTS"],
                "\(masTarget)/\(config.name): setzt CODE_SIGN_ENTITLEMENTS — muss von Xcode synthetisiert werden")
            XCTAssertEqual(settings["INFOPLIST_FILE"] as? String, "Config/Info-MAS.plist",
                "\(masTarget)/\(config.name): falsches INFOPLIST_FILE")
            XCTAssertEqual(settings["ENABLE_APP_SANDBOX"] as? String, "YES",
                "\(masTarget)/\(config.name): ENABLE_APP_SANDBOX fehlt — ohne Entitlements-Datei die einzige Sandbox-Quelle")
            XCTAssertEqual(settings["ENABLE_OUTGOING_NETWORK_CONNECTIONS"] as? String, "YES",
                "\(masTarget)/\(config.name): ohne Netz-Entitlement kein Login/Sync/OTA-Bundle")
        }
    }

    /// Gegenprobe: der DMG-Weg braucht Sparkle genauso zwingend. Fällt die
    /// Compilation Condition weg, kompiliert der `#if SPARKLE`-Code still nicht
    /// mehr mit und die App verliert das Auto-Update, ohne dass ein Build bricht.
    func testDmgTargetKeepsSparkleWiring() throws {
        let project = try Xcodeproj()
        let target = try project.nativeTarget(named: dmgTarget)

        XCTAssertTrue(target.packageProducts.contains("Sparkle"),
            "\(dmgTarget) linkt Sparkle nicht mehr — Auto-Update wäre tot")

        for config in target.configurations {
            let settings = config.settings
            let conditions = settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] as? String ?? ""
            XCTAssertTrue(conditions.contains("SPARKLE"),
                "\(dmgTarget)/\(config.name): SPARKLE fehlt in SWIFT_ACTIVE_COMPILATION_CONDITIONS")
            XCTAssertEqual(settings["CODE_SIGN_ENTITLEMENTS"] as? String, "Config/Focuseditor.entitlements",
                "\(dmgTarget)/\(config.name): Entitlements-Datei fehlt (Sparkle-Installer-XPC)")
            XCTAssertEqual(settings["INFOPLIST_FILE"] as? String, "Config/Info.plist",
                "\(dmgTarget)/\(config.name): falsches INFOPLIST_FILE")
        }
    }

    /// Beide App-Targets müssen dieselbe Bundle-ID tragen: Umsteiger vom DMG in
    /// den Store behalten so Keychain-Token, UserDefaults und den lokalen
    /// SQLite-Spiegel.
    func testBothAppTargetsShareBundleIdentifier() throws {
        let project = try Xcodeproj()
        let ids = try [dmgTarget, masTarget].flatMap { name in
            try project.nativeTarget(named: name).configurations.map {
                $0.settings["PRODUCT_BUNDLE_IDENTIFIER"] as? String ?? "<fehlt>"
            }
        }
        XCTAssertEqual(Set(ids).count, 1,
            "App-Targets haben verschiedene Bundle-IDs (\(Set(ids).sorted())) — Umsteiger verlieren Token + lokale Daten")
    }

    /// Beide App-Targets hängen an derselben `PBXFileSystemSynchronizedRootGroup`
    /// — nur dadurch landen neue Swift-Dateien automatisch in beiden Kanälen und
    /// es entsteht keine zweite Codebasis.
    func testBothAppTargetsShareSynchronizedSourceGroup() throws {
        let project = try Xcodeproj()
        let dmgGroups = Set(try project.nativeTarget(named: dmgTarget).synchronizedGroups)
        let masGroups = Set(try project.nativeTarget(named: masTarget).synchronizedGroups)

        XCTAssertFalse(masGroups.isEmpty, "\(masTarget) hat keine synchronisierte Quell-Gruppe")
        XCTAssertEqual(dmgGroups, masGroups,
            "App-Targets teilen die Quell-Gruppe nicht mehr — neue Dateien fehlen in einem der beiden Kanäle")
    }

    /// [Version.xcconfig](Version.xcconfig) hängt auf **Projektebene** als
    /// Base-Configuration: ein Versions-Bump gilt damit für beide Kanäle. Hängt
    /// sie stattdessen an einem Target, laufen DMG- und Store-Version auseinander.
    func testVersionXcconfigIsProjectWide() throws {
        let project = try Xcodeproj()
        for config in try project.projectConfigurations() {
            XCTAssertEqual(config.baseConfigurationName, "Version.xcconfig",
                "Projekt-Konfiguration '\(config.name)' nutzt Version.xcconfig nicht als Base-Config")
        }
    }

    // MARK: - Helpers

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // schreibwerkstatt-focuseditorTests/
            .deletingLastPathComponent()   // <repo>/
    }

    private func plist(named name: String) throws -> [String: Any] {
        let url = Self.repoRoot().appendingPathComponent("Config/\(name)")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("\(url.path) nicht gefunden — andere Maschine/CI?")
        }
        let data = try Data(contentsOf: url)
        guard let dict = try PropertyListSerialization
            .propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            XCTFail("\(name) ist kein Plist-Dictionary")
            return [:]
        }
        return dict
    }

    /// Minimaler Leser für `project.pbxproj` (OpenStep-Plist). Auflösung über
    /// Target-Namen, damit der Test UUID-Änderungen von Xcode übersteht.
    private struct Xcodeproj {
        struct Configuration {
            let name: String
            let settings: [String: Any]
            let baseConfigurationName: String?
        }
        struct Target {
            let configurations: [Configuration]
            let packageProducts: [String]
            let synchronizedGroups: [String]
        }

        private let objects: [String: [String: Any]]
        private let rootObjectID: String

        init() throws {
            let url = DistributionTargetsTests.repoRoot()
                .appendingPathComponent("schreibwerkstatt-focuseditor.xcodeproj/project.pbxproj")
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw XCTSkip("project.pbxproj nicht gefunden — andere Maschine/CI?")
            }
            let data = try Data(contentsOf: url)
            guard let root = try PropertyListSerialization
                    .propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let objects = root["objects"] as? [String: Any],
                  let rootObjectID = root["rootObject"] as? String else {
                throw XCTSkip("project.pbxproj nicht als Plist lesbar (Xcode-Format geändert?)")
            }
            self.objects = objects.compactMapValues { $0 as? [String: Any] }
            self.rootObjectID = rootObjectID
        }

        func nativeTarget(named name: String) throws -> Target {
            guard let target = objects.values.first(where: {
                $0["isa"] as? String == "PBXNativeTarget" && $0["name"] as? String == name
            }) else {
                XCTFail("Target '\(name)' nicht in der Projektdatei gefunden")
                throw XCTSkip("Target '\(name)' fehlt")
            }
            return Target(
                configurations: configurations(ofList: target["buildConfigurationList"] as? String),
                packageProducts: (target["packageProductDependencies"] as? [String] ?? [])
                    .compactMap { objects[$0]?["productName"] as? String },
                synchronizedGroups: target["fileSystemSynchronizedGroups"] as? [String] ?? [])
        }

        func projectConfigurations() throws -> [Configuration] {
            configurations(ofList: objects[rootObjectID]?["buildConfigurationList"] as? String)
        }

        private func configurations(ofList listID: String?) -> [Configuration] {
            guard let listID, let ids = objects[listID]?["buildConfigurations"] as? [String] else { return [] }
            return ids.compactMap { id in
                guard let config = objects[id] else { return nil }
                let baseID = config["baseConfigurationReference"] as? String
                return Configuration(
                    name: config["name"] as? String ?? "?",
                    settings: config["buildSettings"] as? [String: Any] ?? [:],
                    baseConfigurationName: baseID.flatMap { objects[$0]?["path"] as? String })
            }
        }
    }
}
