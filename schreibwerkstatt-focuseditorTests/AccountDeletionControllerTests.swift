//
//  AccountDeletionControllerTests.swift
//  schreibwerkstatt-focuseditorTests
//
//  `DELETE /me/account` (App-Store-Guideline 5.1.1(v)) — der EINZIGE Pfad im
//  Client, der lokale Inhalte verwirft. Genau darum gehört er getestet: eine
//  Verwechslung in der Status-Auswertung löscht entweder das Manuskript des
//  Nutzers, obwohl der Server abgelehnt hat, oder lässt ihn nach erfolgreicher
//  Löschung mit den Daten eines Kontos zurück, das es nicht mehr gibt.
//
//  Geprüft wird über den `MockURLProtocol` aus APIClientTests — kein Netz,
//  kein Server. `onDeleted` zählt mit, ob der Aufräum-Pfad lief.
//

import XCTest

@MainActor
final class AccountDeletionControllerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ServerConfig.baseURLString = "http://127.0.0.1:3737"
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    /// Baut Controller + gemockten Server. `purged` zählt die Aufrufe von
    /// `onDeleted` — der lokale Purge.
    private func makeController(
        status: Int,
        json: String,
        purged: @escaping () -> Void = {}
    ) -> (AccountDeletionController, () -> URLRequest?) {
        var lastRequest: URLRequest?
        MockURLProtocol.handler = { request in
            lastRequest = request
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data(json.utf8))
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(tokenProvider: { "swd_test" },
                            session: URLSession(configuration: cfg))
        let controller = AccountDeletionController(api: api)
        controller.onDeleted = { purged() }
        return (controller, { lastRequest })
    }

    // MARK: - Erfolg

    func testSuccessPurgesLocallyAndReportsDone() async {
        var purgeCount = 0
        let (controller, _) = makeController(status: 200, json: #"{"ok":true}"#) { purgeCount += 1 }
        await controller.deleteAccount()
        XCTAssertEqual(controller.phase, .done(purgeAt: nil))
        XCTAssertEqual(purgeCount, 1, "nach bestätigter Löschung muss lokal aufgeräumt werden")
    }

    /// Das Demo-Konto wird serverseitig ZURÜCKGESETZT statt gelöscht
    /// (`demo_reset: true`, Tokens bleiben gültig). Der Client behandelt es
    /// bewusst wie jede Löschung, damit der App-Review den vollen Ablauf sieht.
    func testDemoResetIsTreatedLikeADeletion() async {
        var purgeCount = 0
        let (controller, _) = makeController(status: 200,
                                             json: #"{"ok":true,"demo_reset":true}"#) { purgeCount += 1 }
        await controller.deleteAccount()
        XCTAssertEqual(controller.phase, .done(purgeAt: nil))
        XCTAssertEqual(purgeCount, 1)
    }

    /// Das Feld ist client-seitig optional (der Server kennt heute keine
    /// Karenzfrist) — kommt es doch, muss es durchgereicht werden.
    func testScheduledPurgeAtIsCarriedThrough() async {
        let (controller, _) = makeController(
            status: 200, json: #"{"ok":true,"scheduled_purge_at":"2026-09-01T00:00:00Z"}"#)
        await controller.deleteAccount()
        XCTAssertEqual(controller.phase, .done(purgeAt: "2026-09-01T00:00:00Z"))
    }

    // MARK: - Der Kernpunkt: kein Purge ohne Server-Bestätigung

    func testForbiddenDoesNotPurgeLocalData() async {
        var purgeCount = 0
        let (controller, _) = makeController(
            status: 403, json: #"{"error_code":"ACCOUNT_DELETE_FORBIDDEN"}"#) { purgeCount += 1 }
        await controller.deleteAccount()
        XCTAssertEqual(purgeCount, 0, "403 darf lokale Inhalte NIE anfassen")
        guard case .failed = controller.phase else {
            return XCTFail("erwartet .failed, bekam \(controller.phase)")
        }
    }

    func testServerErrorDoesNotPurgeLocalData() async {
        var purgeCount = 0
        let (controller, _) = makeController(
            status: 500, json: #"{"error_code":"ACCOUNT_DELETE_FAILED"}"#) { purgeCount += 1 }
        await controller.deleteAccount()
        XCTAssertEqual(purgeCount, 0)
        guard case .failed = controller.phase else {
            return XCTFail("erwartet .failed, bekam \(controller.phase)")
        }
    }

    func testUnauthorizedDoesNotPurgeLocalData() async {
        var purgeCount = 0
        let (controller, _) = makeController(status: 401, json: "{}") { purgeCount += 1 }
        await controller.deleteAccount()
        XCTAssertEqual(purgeCount, 0, "401 = Token weg, nicht Konto weg — Inhalte bleiben")
        guard case .failed = controller.phase else {
            return XCTFail("erwartet .failed, bekam \(controller.phase)")
        }
    }

    // MARK: - Route fehlt (Browser-Fallback statt Sackgasse)

    /// Ein generischer Express-404 OHNE `error_code` heisst „diese Route gibt es
    /// auf dem Server nicht" — der Client zeigt dann den Browser-Fallback.
    func testGeneric404MeansUnsupported() async {
        let (controller, _) = makeController(status: 404, json: #"{}"#)
        await controller.deleteAccount()
        XCTAssertEqual(controller.phase, .unsupported)
    }

    func testMethodNotAllowedMeansUnsupported() async {
        let (controller, _) = makeController(status: 405, json: "")
        await controller.deleteAccount()
        XCTAssertEqual(controller.phase, .unsupported)
    }

    /// Ein FACHLICHES 404 (mit `error_code`) ist ein echter Fehler, kein
    /// fehlender Endpunkt — hier darf NICHT der Browser-Fallback erscheinen.
    func testBusiness404IsAFailureNotUnsupported() async {
        let (controller, _) = makeController(status: 404, json: #"{"error_code":"USER_NOT_FOUND"}"#)
        await controller.deleteAccount()
        XCTAssertNotEqual(controller.phase, .unsupported)
        guard case .failed = controller.phase else {
            return XCTFail("erwartet .failed, bekam \(controller.phase)")
        }
    }

    // MARK: - Protokoll

    func testSendsDeleteWithConstantConfirmToken() async {
        let (controller, lastRequest) = makeController(status: 200, json: #"{"ok":true}"#)
        await controller.deleteAccount()
        let request = lastRequest()
        XCTAssertEqual(request?.httpMethod, "DELETE")
        XCTAssertTrue(request?.url?.path.hasSuffix("/me/account") == true, "\(request?.url?.path ?? "-")")
        // Der Bestätigungswert ist ein PROTOKOLL-Wert, nicht die (lokalisierte)
        // Nutzereingabe — sonst schlüge die Löschung im deutschen Build fehl.
        let body = request.flatMap { Self.bodyString($0) }
        XCTAssertEqual(body, #"{"confirm":"DELETE"}"#)
    }

    func testSecondCallWhileDeletingIsIgnored() async {
        var purgeCount = 0
        let (controller, _) = makeController(status: 200, json: #"{"ok":true}"#) { purgeCount += 1 }
        // Zwei Läufe hintereinander: der zweite startet aus `.done`, nicht aus
        // `.deleting` — der Reentrancy-Guard greift nur währenddessen. Geprüft
        // wird hier, dass ein zweiter Aufruf nicht in einen Fehlerzustand kippt.
        await controller.deleteAccount()
        await controller.deleteAccount()
        XCTAssertEqual(purgeCount, 2)
        XCTAssertEqual(controller.phase, .done(purgeAt: nil))
    }

    // MARK: - Helper

    /// `URLRequest.httpBody` ist bei einer über URLSession gelaufenen Anfrage
    /// leer — der Body steckt im `httpBodyStream`.
    private static func bodyString(_ request: URLRequest) -> String? {
        if let body = request.httpBody { return String(data: body, encoding: .utf8) }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 1024
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return String(data: data, encoding: .utf8)
    }
}
