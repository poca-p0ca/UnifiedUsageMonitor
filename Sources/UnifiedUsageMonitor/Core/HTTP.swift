import Foundation

enum HTTP {
    /// Shared session with a short timeout — a menu bar app should never hang
    /// waiting on a stalled quota call.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.httpAdditionalHeaders = [:]
        return URLSession(configuration: config)
    }()

    /// Performs the request and maps transport-level failures onto ProviderError.
    /// Returns the body for any status so callers can decide what 401/429 mean
    /// in their own context (Anthropic and OpenAI disagree on both).
    static func send(_ request: URLRequest) async throws -> (status: Int, body: Data, headers: [AnyHashable: Any]) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.http(status: -1, body: L10n.t("error.notHTTP", "Not an HTTP response"))
        }
        return (http.statusCode, data, http.allHeaderFields)
    }

    static func retryAfter(from headers: [AnyHashable: Any]) -> TimeInterval? {
        guard let raw = headers["Retry-After"] ?? headers["retry-after"] else { return nil }
        if let seconds = Double("\(raw)") { return seconds }
        return nil
    }

    static func text(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
    }
}
