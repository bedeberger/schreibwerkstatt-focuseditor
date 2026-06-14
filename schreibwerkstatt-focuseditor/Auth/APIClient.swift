//
//  APIClient.swift
//  schreibwerkstatt-focuseditor
//
//  Schmaler HTTP-Client für den schreibwerkstatt-Server. Setzt bei
//  jedem Request den `Authorization: Bearer swd_…`-Header aus der
//  Keychain (via `tokenProvider`). Netzwerk macht ausschließlich der
//  Swift-Kern — die WebView kennt weder Server noch Token.
//
//  401 → `AuthError.unauthorized`; zusätzlich wird `onUnauthorized`
//  gemeldet, damit die AuthStore das Token verwerfen und auf Re-Login
//  schalten kann. Lokale Inhalte werden dabei NIE verworfen.
//

import Foundation

final class APIClient {
    /// Liefert das aktuelle Klartext-Token (oder nil), z. B. aus der Keychain.
    private let tokenProvider: () -> String?
    /// Wird bei 401 aufgerufen (z. B. um die Session zu beenden).
    var onUnauthorized: (() -> Void)?

    private let session: URLSession
    private let decoder = JSONDecoder()

    init(tokenProvider: @escaping () -> String?,
         session: URLSession = .shared) {
        self.tokenProvider = tokenProvider
        self.session = session
    }

    enum Method: String {
        case GET, POST, PUT, DELETE
    }

    /// Führt einen Request gegen `ServerConfig.baseURL` + `path` aus und
    /// dekodiert die Antwort. `overrideToken` erlaubt das Validieren eines
    /// noch nicht gespeicherten Tokens beim Login.
    @discardableResult
    func send<T: Decodable>(
        _ path: String,
        method: Method = .GET,
        body: Encodable? = nil,
        overrideToken: String? = nil,
        decode type: T.Type
    ) async throws -> T {
        let data = try await sendRaw(path, method: method, body: body, overrideToken: overrideToken)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw AuthError.decoding(error)
        }
    }

    /// Variante ohne dekodierten Body (z. B. revoke/delete: `{ ok: true }`).
    func sendVoid(
        _ path: String,
        method: Method = .GET,
        body: Encodable? = nil,
        overrideToken: String? = nil
    ) async throws {
        _ = try await sendRaw(path, method: method, body: body, overrideToken: overrideToken)
    }

    /// Kern: baut den Request, prüft Statuscodes, mappt Fehler.
    private func sendRaw(
        _ path: String,
        method: Method,
        body: Encodable?,
        overrideToken: String?
    ) async throws -> Data {
        guard let baseURL = ServerConfig.baseURL,
              let url = URL(string: path, relativeTo: baseURL) else {
            throw AuthError.invalidServerURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let token = overrideToken ?? tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AuthError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AuthError.server(status: -1, code: nil, body: nil)
        }

        switch http.statusCode {
        case 200...299:
            return data
        case 401:
            onUnauthorized?()
            throw AuthError.unauthorized
        default:
            let code = (try? decoder.decode(ServerErrorBody.self, from: data))?.error_code
            throw AuthError.server(status: http.statusCode, code: code, body: data)
        }
    }
}

/// Type-Erasure, damit `Encodable` als Parameter funktioniert.
private struct AnyEncodable: Encodable {
    private let encodeFunc: (Encoder) throws -> Void
    init(_ wrapped: Encodable) {
        self.encodeFunc = wrapped.encode
    }
    func encode(to encoder: Encoder) throws {
        try encodeFunc(encoder)
    }
}
