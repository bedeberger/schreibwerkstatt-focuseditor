//
//  MiniZip.swift
//  schreibwerkstatt-focuseditor
//
//  Minimaler, abhängigkeitsfreier ZIP-Entpacker für das OTA-Editor-Bundle
//  (GET /content/editor-bundle.zip, JSZip/DEFLATE). Die App läuft im App-Sandbox
//  → kein `Process`/`unzip`, und Foundation hat keinen ZIP-Reader. Statt einer
//  SPM-Dependency (ZIPFoundation) parsen wir das Central Directory selbst und
//  inflaten DEFLATE über das bordeigene `Compression`-Framework.
//
//  Bewusst minimal und auf unser eigenes, kontrolliertes ZIP zugeschnitten:
//   • liest Größen/Offsets aus dem Central Directory (robust gegen
//     Data-Descriptors, bei denen der Local-Header Nullgrößen trägt),
//   • unterstützt „stored" (0) und „deflate" (8) — was JSZip erzeugt,
//   • kein ZIP64 (Bundle ist klein; 0xFFFFFFFF-Marker → Fehler statt Fehlinterpret.).
//

import Foundation
import Compression

enum MiniZipError: Error {
    case notAZip                 // EOCD nicht gefunden
    case malformed(String)       // Header-/Offset-Inkonsistenz
    case unsupported(String)     // ZIP64 / unbekannte Kompression
    case inflateFailed(String)   // DEFLATE-Dekompression fehlgeschlagen
}

enum MiniZip {

    /// Ein entpackter Eintrag: relativer POSIX-Pfad + roher Inhalt.
    struct Entry {
        let path: String
        let data: Data
    }

    // ── Signaturen ───────────────────────────────────────────────────────────
    private static let eocdSig: UInt32 = 0x0605_4b50   // PK\x05\x06
    private static let cdSig: UInt32    = 0x0201_4b50   // PK\x01\x02
    private static let lfhSig: UInt32   = 0x0403_4b50   // PK\x03\x04

    /// Entpackt alle Dateieinträge eines ZIP-Puffers. Verzeichniseinträge
    /// (Pfad endet auf „/") werden übersprungen.
    static func entries(in input: Data) throws -> [Entry] {
        // Auf startIndex 0 normalisieren: der Parser rechnet durchgängig mit
        // absoluten Offsets (Slices aus URLSession sind i. d. R. schon 0-basiert).
        let data = input.startIndex == 0 ? input : Data(input)
        let eocd = try findEOCD(in: data)
        let total = readU16(data, eocd + 10)
        let cdOffset = Int(readU32(data, eocd + 16))
        guard cdOffset < data.count else { throw MiniZipError.malformed("CD-Offset außerhalb") }

        var out: [Entry] = []
        var p = cdOffset
        for _ in 0..<total {
            guard p + 46 <= data.count, readU32(data, p) == cdSig else {
                throw MiniZipError.malformed("Central-Directory-Header erwartet @\(p)")
            }
            let method   = readU16(data, p + 10)
            let compSize = readU32(data, p + 20)
            let rawSize  = readU32(data, p + 24)
            let nameLen  = Int(readU16(data, p + 28))
            let extraLen = Int(readU16(data, p + 32))
            let commLen  = Int(readU16(data, p + 34))
            let lhOffset = Int(readU32(data, p + 42))

            if compSize == 0xFFFF_FFFF || rawSize == 0xFFFF_FFFF || lhOffset == 0xFFFF_FFFF {
                throw MiniZipError.unsupported("ZIP64 nicht unterstützt")
            }

            let nameRange = (p + 46)..<(p + 46 + nameLen)
            guard nameRange.upperBound <= data.count else { throw MiniZipError.malformed("Name-Bereich") }
            let name = String(decoding: data[nameRange], as: UTF8.self)

            if !name.hasSuffix("/") {
                let raw = try extractPayload(data, localHeaderOffset: lhOffset,
                                             method: method,
                                             compressedSize: Int(compSize),
                                             uncompressedSize: Int(rawSize))
                out.append(Entry(path: name, data: raw))
            }

            p += 46 + nameLen + extraLen + commLen
        }
        return out
    }

    // ── Intern ────────────────────────────────────────────────────────────────

    /// Liest die komprimierten Bytes ab dem Local-File-Header und entpackt sie.
    /// Die Daten-Startposition wird aus dem LOCAL-Header berechnet (dessen
    /// name/extra-Längen können von denen im Central Directory abweichen).
    private static func extractPayload(_ data: Data,
                                       localHeaderOffset: Int,
                                       method: UInt16,
                                       compressedSize: Int,
                                       uncompressedSize: Int) throws -> Data {
        guard localHeaderOffset + 30 <= data.count, readU32(data, localHeaderOffset) == lfhSig else {
            throw MiniZipError.malformed("Local-File-Header erwartet @\(localHeaderOffset)")
        }
        let nameLen  = Int(readU16(data, localHeaderOffset + 26))
        let extraLen = Int(readU16(data, localHeaderOffset + 28))
        let start = localHeaderOffset + 30 + nameLen + extraLen
        let end = start + compressedSize
        guard end <= data.count else { throw MiniZipError.malformed("Nutzdaten außerhalb") }
        let comp = data.subdata(in: start..<end)

        switch method {
        case 0:  // stored
            return comp
        case 8:  // deflate (raw, RFC 1951) — Apples COMPRESSION_ZLIB ist genau das
            return try inflate(comp, expectedSize: uncompressedSize)
        default:
            throw MiniZipError.unsupported("Kompressionsmethode \(method)")
        }
    }

    /// Raw-DEFLATE-Dekompression in einen Puffer bekannter Größe.
    private static func inflate(_ comp: Data, expectedSize: Int) throws -> Data {
        if expectedSize == 0 { return Data() }
        var dst = Data(count: expectedSize)
        let written = dst.withUnsafeMutableBytes { dstRaw -> Int in
            comp.withUnsafeBytes { srcRaw -> Int in
                compression_decode_buffer(
                    dstRaw.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                    srcRaw.bindMemory(to: UInt8.self).baseAddress!, comp.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else {
            throw MiniZipError.inflateFailed("erwartet \(expectedSize), erhalten \(written)")
        }
        return dst
    }

    /// Sucht das End-of-Central-Directory rückwärts (es kann ein Kommentar von
    /// bis zu 65535 Bytes folgen). Liefert den Offset der EOCD-Signatur.
    private static func findEOCD(in data: Data) throws -> Int {
        let minSize = 22
        guard data.count >= minSize else { throw MiniZipError.notAZip }
        let maxBack = min(data.count, minSize + 0xFFFF)
        var i = data.count - minSize
        let lowest = data.count - maxBack
        while i >= lowest {
            if readU32(data, i) == eocdSig { return i }
            i -= 1
        }
        throw MiniZipError.notAZip
    }

    // Little-Endian-Leser (ZIP ist durchgängig LE).
    private static func readU16(_ d: Data, _ o: Int) -> UInt16 {
        let b = d.startIndex + o
        return UInt16(d[b]) | (UInt16(d[b + 1]) << 8)
    }
    private static func readU32(_ d: Data, _ o: Int) -> UInt32 {
        let b = d.startIndex + o
        return UInt32(d[b]) | (UInt32(d[b + 1]) << 8) | (UInt32(d[b + 2]) << 16) | (UInt32(d[b + 3]) << 24)
    }
}
