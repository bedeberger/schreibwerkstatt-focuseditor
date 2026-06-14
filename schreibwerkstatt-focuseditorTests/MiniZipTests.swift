//
//  MiniZipTests.swift
//  schreibwerkstatt-focuseditorTests
//
//  Offline-Regressionstests für den bordeigenen ZIP-Entpacker (MiniZip.swift),
//  der das OTA-Editor-Bundle (GET /content/editor-bundle.zip) auspackt. Bricht
//  dieser Pfad, lädt der Editor nicht — also voll abgesichert: stored + deflate,
//  Verzeichnis-Skip, Central-Directory mit Extra-Feld, Fehlerfälle.
//
//  Die Test-ZIPs werden hier byteweise selbst gebaut (kein `Process`/`zip` im
//  Sandbox), DEFLATE über dasselbe Compression-Framework wie MiniZip — so ist
//  der Encode/Decode-Pfad symmetrisch (raw DEFLATE, RFC 1951).
//

import XCTest
import Compression

final class MiniZipTests: XCTestCase {

    // MARK: - Tests

    func testExtractsStoredEntry() throws {
        let payload = Data("Hallo Welt — äöü".utf8)
        let zip = buildZip([FileSpec(name: "a.txt", data: payload, method: 0)])
        let entries = try MiniZip.entries(in: zip)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.path, "a.txt")
        XCTAssertEqual(entries.first?.data, payload)
    }

    func testInflatesDeflatedEntry() throws {
        // Gut komprimierbarer Inhalt → method 8 greift wirklich.
        let payload = Data(String(repeating: "abcABC123 ", count: 500).utf8)
        let zip = buildZip([FileSpec(name: "js/focus.js", data: payload, method: 8)])
        let entries = try MiniZip.entries(in: zip)
        XCTAssertEqual(entries.first?.path, "js/focus.js")
        XCTAssertEqual(entries.first?.data, payload, "DEFLATE-Roundtrip muss bit-genau sein")
    }

    func testSkipsDirectoryEntries() throws {
        let zip = buildZip([
            FileSpec(name: "js/", data: Data(), method: 0),                 // Verzeichnis
            FileSpec(name: "js/focus.js", data: Data("x".utf8), method: 0),
        ])
        let entries = try MiniZip.entries(in: zip)
        XCTAssertEqual(entries.map(\.path), ["js/focus.js"], "Verzeichnis-Einträge werden übersprungen")
    }

    func testHandlesMultipleEntriesWithCentralDirectoryExtraField() throws {
        // Regression: das Central Directory trägt hier ein Extra-Feld (z. B.
        // Extended-Timestamp). Wird die Extra-Länge falsch gelesen, rutscht der
        // CD-Parser aus dem Tritt und der 2. Eintrag wird nicht gefunden.
        let extra = Data([0x55, 0x54, 0x05, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00])  // "UT" Extended-Timestamp
        let zip = buildZip([
            FileSpec(name: "css/style.css", data: Data("body{}".utf8), method: 0, cdExtra: extra),
            FileSpec(name: "js/app.js", data: Data("let x=1".utf8), method: 8, cdExtra: extra),
        ])
        let entries = try MiniZip.entries(in: zip)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first { $0.path == "css/style.css" }?.data, Data("body{}".utf8))
        XCTAssertEqual(entries.first { $0.path == "js/app.js" }?.data, Data("let x=1".utf8))
    }

    func testThrowsOnNonZipInput() {
        XCTAssertThrowsError(try MiniZip.entries(in: Data("überhaupt kein zip".utf8))) { error in
            guard case MiniZipError.notAZip = error else {
                return XCTFail("Erwartete .notAZip, bekam \(error)")
            }
        }
    }

    func testThrowsOnTooShortInput() {
        XCTAssertThrowsError(try MiniZip.entries(in: Data([0x50, 0x4B]))) { error in
            guard case MiniZipError.notAZip = error else {
                return XCTFail("Erwartete .notAZip, bekam \(error)")
            }
        }
    }

    // MARK: - ZIP-Builder (byteweise, Little-Endian)

    private struct FileSpec {
        let name: String
        let data: Data
        let method: UInt16
        var cdExtra: Data = Data()
    }

    private func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
    private func u32(_ v: Int) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
    }

    /// Raw-DEFLATE (RFC 1951) — exakt das, was MiniZip via COMPRESSION_ZLIB inflated.
    private func rawDeflate(_ input: Data) -> Data {
        guard !input.isEmpty else { return Data() }
        let cap = input.count + 256
        var dst = Data(count: cap)
        let n = dst.withUnsafeMutableBytes { d in
            input.withUnsafeBytes { s in
                compression_encode_buffer(
                    d.bindMemory(to: UInt8.self).baseAddress!, cap,
                    s.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        precondition(n > 0, "DEFLATE-Encode fehlgeschlagen (Puffer zu klein?)")
        return dst.prefix(n)
    }

    /// Baut ein minimal-gültiges ZIP (Local Headers + Central Directory + EOCD).
    /// CRC bleibt 0 — MiniZip prüft die Prüfsumme bewusst nicht.
    private func buildZip(_ specs: [FileSpec]) -> Data {
        var local = Data()
        var offsets: [Int] = []
        var comps: [Data] = []

        for s in specs {
            let comp = s.method == 8 ? rawDeflate(s.data) : s.data
            comps.append(comp)
            offsets.append(local.count)
            let name = Array(s.name.utf8)
            local.append(contentsOf: u32(0x04034b50))   // LFH-Signatur
            local.append(contentsOf: u16(20))           // version needed
            local.append(contentsOf: u16(0))            // flags
            local.append(contentsOf: u16(Int(s.method)))
            local.append(contentsOf: u16(0))            // mod time
            local.append(contentsOf: u16(0))            // mod date
            local.append(contentsOf: u32(0))            // crc-32 (ungeprüft)
            local.append(contentsOf: u32(comp.count))   // comp size
            local.append(contentsOf: u32(s.data.count)) // uncomp size
            local.append(contentsOf: u16(name.count))   // name len
            local.append(contentsOf: u16(0))            // extra len (lokal) = 0
            local.append(contentsOf: name)
            local.append(comp)
        }

        let cdStart = local.count
        var cd = Data()
        for (i, s) in specs.enumerated() {
            let name = Array(s.name.utf8)
            cd.append(contentsOf: u32(0x02014b50))      // CD-Signatur
            cd.append(contentsOf: u16(20))              // version made by
            cd.append(contentsOf: u16(20))              // version needed
            cd.append(contentsOf: u16(0))               // flags
            cd.append(contentsOf: u16(Int(s.method)))
            cd.append(contentsOf: u16(0))               // mod time
            cd.append(contentsOf: u16(0))               // mod date
            cd.append(contentsOf: u32(0))               // crc-32
            cd.append(contentsOf: u32(comps[i].count))  // comp size
            cd.append(contentsOf: u32(s.data.count))    // uncomp size
            cd.append(contentsOf: u16(name.count))      // name len            @28
            cd.append(contentsOf: u16(s.cdExtra.count)) // extra len           @30
            cd.append(contentsOf: u16(0))               // comment len         @32
            cd.append(contentsOf: u16(0))               // disk number start   @34
            cd.append(contentsOf: u16(0))               // internal attrs
            cd.append(contentsOf: u32(0))               // external attrs
            cd.append(contentsOf: u32(offsets[i]))      // local header offset @42
            cd.append(contentsOf: name)
            cd.append(s.cdExtra)
        }

        var out = Data()
        out.append(local)
        out.append(cd)
        out.append(contentsOf: u32(0x06054b50))         // EOCD-Signatur
        out.append(contentsOf: u16(0))                  // disk number
        out.append(contentsOf: u16(0))                  // disk with CD
        out.append(contentsOf: u16(specs.count))        // entries this disk
        out.append(contentsOf: u16(specs.count))        // total entries
        out.append(contentsOf: u32(cd.count))           // CD size
        out.append(contentsOf: u32(cdStart))            // CD offset
        out.append(contentsOf: u16(0))                  // comment len
        return out
    }
}
