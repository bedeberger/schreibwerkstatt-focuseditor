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

    /// POST mit JSON-Body, der fachliche 4xx-Antworten als `(status, data)`
    /// durchreicht, statt sie zu werfen. Gedacht für Endpoints, deren 4xx eine
    /// Bedeutung trägt, die der Aufrufer deuten muss — z. B. liefert
    /// `POST /languagetool/check` ein `404`, wenn LanguageTool serverseitig
    /// deaktiviert ist (kein Fehler, sondern „Feature aus").
    ///
    /// `401` schlägt wie üblich auf `onUnauthorized` durch und wirft; `5xx`
    /// und Netzfehler werfen ebenfalls. Lokale Inhalte werden NIE verworfen.
    func postExpectingJSON(_ path: String, body: Encodable) async throws -> (status: Int, data: Data) {
        guard let baseURL = ServerConfig.baseURL,
              let url = URL(string: path, relativeTo: baseURL) else {
            throw AuthError.invalidServerURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = Method.POST.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(AnyEncodable(body))

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
        case 401:
            onUnauthorized?()
            throw AuthError.unauthorized
        case 500...599:
            let code = (try? decoder.decode(ServerErrorBody.self, from: data))?.error_code
            throw AuthError.server(status: http.statusCode, code: code, body: data)
        default:
            // 2xx und fachliche 4xx (z. B. 404/413) reicht der Aufrufer aus.
            return (http.statusCode, data)
        }
    }

    /// Ergebnis eines Roh-GET ohne JSON-Decode (für Nicht-JSON-Ressourcen wie
    /// das Editor-Bundle-ZIP). `notModified` = Server-304 auf `If-None-Match`.
    struct RawResponse {
        let notModified: Bool
        let data: Data
        let etag: String?
    }

    /// Roh-GET für binäre Ressourcen. Behandelt `304 Not Modified` NICHT als
    /// Fehler (für konditionale Anfragen via `If-None-Match`). 401 schlägt wie
    /// üblich auf `onUnauthorized` durch.
    func getRaw(_ path: String, ifNoneMatch etag: String? = nil) async throws -> RawResponse {
        guard let baseURL = ServerConfig.baseURL,
              let url = URL(string: path, relativeTo: baseURL) else {
            throw AuthError.invalidServerURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = Method.GET.rawValue
        if let token = tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
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

        let responseETag = http.value(forHTTPHeaderField: "ETag")
        switch http.statusCode {
        case 304:
            return RawResponse(notModified: true, data: Data(), etag: responseETag ?? etag)
        case 200...299:
            return RawResponse(notModified: false, data: data, etag: responseETag)
        case 401:
            onUnauthorized?()
            throw AuthError.unauthorized
        default:
            let code = (try? decoder.decode(ServerErrorBody.self, from: data))?.error_code
            throw AuthError.server(status: http.statusCode, code: code, body: data)
        }
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
