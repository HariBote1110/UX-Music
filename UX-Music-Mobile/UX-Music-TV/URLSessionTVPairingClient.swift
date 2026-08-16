import Foundation

/// Real `TVPairingClient` backed by `URLSession`, calling the same public
/// `/v1/pairing/start` and `/v1/pairing/confirm` endpoints the desktop app uses
/// (`server/app_pairing.go`). Mirrors the request/response shapes of
/// `RemoteAPIClient.redeemPairingSecret` (see `UX-Music-Mobile/Services/RemoteAPIClient.swift`).
struct URLSessionTVPairingClient: TVPairingClient {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func start(baseURL: String, deviceId: String, displayName: String) async throws -> TVPairingStart {
        guard let base = URL(string: baseURL) else { throw TVPairingError.invalidResponse }
        var request = URLRequest(url: base.appendingPathComponent("v1/pairing/start"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "deviceId": deviceId,
            "displayName": displayName,
        ])

        let (data, response) = try await perform(request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionId = obj["sessionId"] as? String, !sessionId.isEmpty,
              let code = obj["code"] as? String, !code.isEmpty
        else {
            throw TVPairingError.invalidResponse
        }
        return TVPairingStart(sessionId: sessionId, code: code, expiresAt: obj["expiresAt"] as? String ?? "")
    }

    func confirm(baseURL: String, sessionId: String, code: String) async throws -> TVPairingConfirmed {
        guard let base = URL(string: baseURL) else { throw TVPairingError.invalidResponse }
        var request = URLRequest(url: base.appendingPathComponent("v1/pairing/confirm"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "sessionId": sessionId,
            "code": code,
        ])

        let (data, response) = try await perform(request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceId = obj["deviceId"] as? String, !deviceId.isEmpty,
              let token = obj["token"] as? String, !token.isEmpty
        else {
            throw TVPairingError.invalidResponse
        }
        return TVPairingConfirmed(deviceId: deviceId, token: token)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw TVPairingError.network(error.localizedDescription)
        }
    }
}
