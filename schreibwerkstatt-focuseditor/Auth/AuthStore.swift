//
//  AuthStore.swift
//  schreibwerkstatt-focuseditor
//
//  Zentrale Auth-Zustandsmaschine für die SwiftUI-Shell. Hält das
//  Device-Token in der Keychain, validiert es gegen den Server und
//  stellt einen vorkonfigurierten `APIClient` für den restlichen
//  Swift-Kern (Sync etc.) bereit.
//
//  Datenverlust-Schutz: Bei 401/Logout wird nur das Token entfernt und
//  auf Re-Login geschaltet — lokale Inhalte bleiben unangetastet.
//

import Foundation
import Combine

@MainActor
final class AuthStore: ObservableObject {

    /// Keychain-Koordinaten des Device-Tokens.
    private static let keychainService = "ch.schreibwerkstatt.focuseditor.device-token"
    private static let keychainAccount = "default"

    enum State: Equatable {
        case unknown      // Startzustand, vor Bootstrap
        case signedOut    // kein gültiges Token → Login nötig
        case validating   // Login-/Bootstrap-Prüfung läuft
        case signedIn     // Token vorhanden und (zuletzt) akzeptiert
    }

    @Published private(set) var state: State = .unknown
    @Published var lastError: String?

    /// Vorkonfigurierter Client für authentifizierte Requests.
    /// Zieht das Token bei jedem Request frisch aus der Keychain.
    let api: APIClient

    init() {
        self.api = APIClient(tokenProvider: {
            Keychain.read(service: AuthStore.keychainService,
                          account: AuthStore.keychainAccount)
        })
        // 401 aus beliebigem Request → Session beenden (ohne Datenverlust).
        self.api.onUnauthorized = { [weak self] in
            Task { @MainActor in self?.handleUnauthorized() }
        }
    }

    /// Ist ein Token gespeichert? (Format-/Server-unabhängig.)
    var hasStoredToken: Bool {
        Keychain.read(service: Self.keychainService, account: Self.keychainAccount) != nil
    }

    // MARK: - Lifecycle

    /// Beim App-Start: gespeichertes Token gegen den Server prüfen.
    /// Bei Netzwerkfehlern bleiben wir optimistisch angemeldet (offline-fähig);
    /// erst ein echtes 401 beendet die Session.
    func bootstrap() async {
        guard hasStoredToken else {
            state = .signedOut
            return
        }
        state = .validating
        do {
            try await probe(token: nil)
            state = .signedIn
        } catch AuthError.unauthorized {
            clearToken()
            state = .signedOut
        } catch {
            // Offline o. Ä.: Token behalten, optimistisch angemeldet.
            state = .signedIn
        }
    }

    // MARK: - Login

    /// Meldet mit Server-URL + eingefügtem Device-Token an.
    /// Reihenfolge: Format prüfen → URL setzen → gegen Server validieren →
    /// erst bei Erfolg in der Keychain ablegen.
    func signIn(serverURLString: String, rawToken: String) async {
        lastError = nil
        let token = DeviceToken.normalize(rawToken)

        guard DeviceToken.isValidFormat(token) else {
            lastError = AuthError.malformedToken.errorDescription
            return
        }
        guard let normalizedURL = ServerConfig.normalizedURL(from: serverURLString) else {
            lastError = AuthError.invalidServerURL.errorDescription
            return
        }

        state = .validating
        ServerConfig.baseURLString = normalizedURL.absoluteString

        do {
            // Token noch nicht gespeichert → explizit mitgeben.
            try await probe(token: token)
            try Keychain.save(token,
                              service: Self.keychainService,
                              account: Self.keychainAccount)
            state = .signedIn
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription
                ?? AuthError.network(error).errorDescription
            state = .signedOut
        }
    }

    // MARK: - Logout / 401

    /// Manueller Logout: Token entfernen, lokale Inhalte bleiben erhalten.
    func signOut() {
        clearToken()
        state = .signedOut
    }

    /// Reaktion auf ein 401 aus laufendem Betrieb.
    private func handleUnauthorized() {
        clearToken()
        lastError = AuthError.unauthorized.errorDescription
        state = .signedOut
    }

    // MARK: - Intern

    /// Validierungs-Probe: `GET /me/device-tokens` funktioniert mit einem
    /// Device-Token (nur das Ausstellen via POST ist gesperrt). 200 → ok,
    /// 401 → ungültig; andere Fehler propagieren (Offline etc.).
    private func probe(token: String?) async throws {
        _ = try await api.send("/me/device-tokens",
                               method: .GET,
                               overrideToken: token,
                               decode: DeviceTokenListResponse.self)
    }

    private func clearToken() {
        Keychain.delete(service: Self.keychainService, account: Self.keychainAccount)
    }
}
