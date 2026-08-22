//
//  ZipFixture.swift
//  schreibwerkstatt-focuseditorTests
//
//  Baut minimal-gültige ZIP-Archive im Speicher (Local Headers + Central
//  Directory + EOCD, Little-Endian von Hand).
//
//  Warum von Hand und nicht mit einer Bibliothek: `MiniZip` ist bewusst
//  dependency-frei (die App ist sandboxed, kein `Process`/`unzip`), und ein
//  Test, der zum Erzeugen seiner Eingabe eine fremde ZIP-Implementierung
//  bräuchte, würde genau die Annahme umgehen, die er prüfen soll.
//
//  Geteilt zwischen `MiniZipTests` (Reader-Ebene) und `EditorBundleStoreTests`
//  (OTA-Ebene: Entpacken, Manifest, atomarer Tausch).
//
//  CRC bleibt 0 — MiniZip prüft die Prüfsumme bewusst nicht.
//

import Foundation
import Compression

enum ZipFixture {



    struct FileSpec {
        let name: String
        let data: Data
        let method: UInt16
        var cdExtra: Data = Data()
    }

    static func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
    static func u32(_ v: Int) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
    }

    /// Raw-DEFLATE (RFC 1951) — exakt das, was MiniZip via COMPRESSION_ZLIB inflated.
    static func rawDeflate(_ input: Data) -> Data {
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
    static func build(_ specs: [FileSpec]) -> Data {
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
