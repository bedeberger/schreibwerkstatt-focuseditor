//
//  DeviceTokenTests.swift
//  schreibwerkstatt-focuseditorTests
//
//  Offline-Regressionstests für das Device-Token-Format. Reine Logik,
//  kein Server — schützt den Vertrag /^swd_[0-9a-f]{64}$/ (Hauptrepo
//  db/device-tokens.js) gegen versehentliche Lockerung/Verschärfung.
//

import XCTest

final class DeviceTokenTests: XCTestCase {

    /// 64 Hex-Zeichen (lowercase) als gültiger Token-Body.
    private let validHex = String(repeating: "a1b2c3d4", count: 8)   // 8 * 8 = 64

    func testAcceptsWellFormedToken() {
        XCTAssertTrue(DeviceToken.isValidFormat("swd_" + validHex))
        XCTAssertEqual(validHex.count, 64)
    }

    func testTrimsWhitespaceBeforeValidating() {
        // Copy-Paste hängt gern Leerzeichen/Newlines an.
        XCTAssertTrue(DeviceToken.isValidFormat("  swd_\(validHex)\n"))
    }

    func testRejectsMissingPrefix() {
        XCTAssertFalse(DeviceToken.isValidFormat(validHex))
        XCTAssertFalse(DeviceToken.isValidFormat("tok_" + validHex))
    }

    func testRejectsWrongLength() {
        XCTAssertFalse(DeviceToken.isValidFormat("swd_" + String(repeating: "a", count: 63)))
        XCTAssertFalse(DeviceToken.isValidFormat("swd_" + String(repeating: "a", count: 65)))
        XCTAssertFalse(DeviceToken.isValidFormat("swd_"))
    }

    func testRejectsUppercaseHex() {
        // Server hasht lowercase-Hex — Großbuchstaben sind kein gültiges Token.
        let upper = String(repeating: "A1B2C3D4", count: 8)
        XCTAssertFalse(DeviceToken.isValidFormat("swd_" + upper))
    }

    func testRejectsNonHexCharacters() {
        let nonHex = String(repeating: "g1b2c3d4", count: 8)   // 'g' ist kein Hex
        XCTAssertFalse(DeviceToken.isValidFormat("swd_" + nonHex))
    }

    func testNormalizeStripsSurroundingWhitespace() {
        XCTAssertEqual(DeviceToken.normalize("  swd_x \n"), "swd_x")
    }
}
