//
//  ServerConfigTests.swift
//  schreibwerkstatt-focuseditorTests
//
//  Offline-Regressionstests für die URL-Normalisierung. Reine Logik.
//  Sichert insbesondere die localhost→127.0.0.1-Zwangsumschreibung (Dev-Server
//  bindet nur IPv4) und die Scheme/Host-Validierung.
//

import XCTest

final class ServerConfigTests: XCTestCase {

    func testStripsTrailingSlashes() {
        let url = ServerConfig.normalizedURL(from: "https://example.com/")
        XCTAssertEqual(url?.absoluteString, "https://example.com")
    }

    func testTrimsWhitespace() {
        let url = ServerConfig.normalizedURL(from: "  https://example.com  ")
        XCTAssertEqual(url?.absoluteString, "https://example.com")
    }

    func testCoercesLocalhostToIPv4() {
        // localhost löst unter macOS bevorzugt auf ::1 auf → Dev-Server (IPv4) nicht erreichbar.
        let url = ServerConfig.normalizedURL(from: "http://localhost:3737")
        XCTAssertEqual(url?.host, "127.0.0.1")
        XCTAssertEqual(url?.port, 3737)
    }

    func testKeepsNonLocalhostHost() {
        let url = ServerConfig.normalizedURL(from: "https://schreibwerkstatt.example/")
        XCTAssertEqual(url?.host, "schreibwerkstatt.example")
        XCTAssertEqual(url?.scheme, "https")
    }

    func testRejectsEmpty() {
        XCTAssertNil(ServerConfig.normalizedURL(from: ""))
        XCTAssertNil(ServerConfig.normalizedURL(from: "   "))
    }

    func testRejectsNonHTTPScheme() {
        XCTAssertNil(ServerConfig.normalizedURL(from: "ftp://example.com"))
        XCTAssertNil(ServerConfig.normalizedURL(from: "file:///etc/hosts"))
    }

    func testRejectsMissingHost() {
        XCTAssertNil(ServerConfig.normalizedURL(from: "http://"))
        XCTAssertNil(ServerConfig.normalizedURL(from: "justtext"))
    }
}
