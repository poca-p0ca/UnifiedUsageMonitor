import Foundation

/// Reads ChatGPT-plan quota from the endpoint the Codex CLI uses.
///
/// Scope caveat worth remembering: this is the *Codex* quota, which is a
/// separate bucket from ChatGPT chat messages. There is no public surface for
/// chat-message usage, and on Pro-tier plans chat is effectively uncapped
/// anyway, so this is the number that actually moves.
final class CodexProvider: UsageProvider {
    let id = "codex"
    let displayName = "ChatGPT · Codex"
    let shortTag = "GPT"
    let minimumInterval: TimeInterval = 180

    private let authPath = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".codex/auth.json")
    private let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    private let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private let userAgent = "codex_cli_rs/0.20.0"

    func isInstalled() -> Bool {
        // `~/.codex` appears on first run regardless of how the CLI was
        // installed, so this needs no knowledge of where the binary went.
        Installed.anyExists([".codex", ".codex/auth.json"])
    }

    func fetch() async throws -> ProviderSnapshot {
        var auth = try loadAuth()

        var (status, body) = try await requestUsage(token: auth.accessToken, accountID: auth.accountID)

        // No expiry is stored in auth.json, so an expired token is discovered
        // rather than predicted: refresh once on 401 and retry.
        if status == 401 {
            auth = try await refresh(auth)
            (status, body) = try await requestUsage(token: auth.accessToken, accountID: auth.accountID)
        }

        DebugLog.dump(body, name: "codex-usage")

        switch status {
        case 200:
            return try parse(body)
        case 401, 403:
            throw ProviderError.authExpired(L10n.t("error.codex.relogin", "Sign in again: run `codex login`"))
        case 429:
            throw ProviderError.rateLimited(retryAfter: nil)
        default:
            throw ProviderError.http(status: status, body: HTTP.text(body))
        }
    }

    private func requestUsage(token: String, accountID: String?) async throws -> (Int, Data) {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountID {
            request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
        }
        let (status, body, _) = try await HTTP.send(request)
        return (status, body)
    }

    // MARK: - Credentials

    private struct Auth {
        var accessToken: String
        var refreshToken: String
        var accountID: String?
        var raw: [String: Any]
    }

    private func loadAuth() throws -> Auth {
        guard let data = try? Data(contentsOf: authPath) else {
            throw ProviderError.notConfigured(L10n.t("error.codex.login", "Sign in: run `codex login`"))
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String,
              let refresh = tokens["refresh_token"] as? String
        else {
            throw ProviderError.notConfigured(L10n.t("error.codex.malformed", "Malformed credentials — run `codex login` again"))
        }
        return Auth(
            accessToken: access,
            refreshToken: refresh,
            accountID: tokens["account_id"] as? String,
            raw: root
        )
    }

    private func refresh(_ auth: Auth) async throws -> Auth {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": auth.refreshToken,
            "scope": "openid profile email",
        ])

        let (status, body, _) = try await HTTP.send(request)
        guard status == 200,
              let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let access = payload["access_token"] as? String
        else {
            DebugLog.note("codex token refresh HTTP \(status)")
            throw ProviderError.authExpired(L10n.t("error.codex.relogin", "Sign in again: run `codex login`"))
        }

        var updated = auth
        updated.accessToken = access
        if let newRefresh = payload["refresh_token"] as? String {
            updated.refreshToken = newRefresh
        }

        var root = auth.raw
        var tokens = (root["tokens"] as? [String: Any]) ?? [:]
        tokens["access_token"] = updated.accessToken
        tokens["refresh_token"] = updated.refreshToken
        if let idToken = payload["id_token"] as? String { tokens["id_token"] = idToken }
        root["tokens"] = tokens
        root["last_refresh"] = ISO8601DateFormatter().string(from: Date())

        // Keep the CLI working: write back in place, preserving 0600.
        if let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted]) {
            try? data.write(to: authPath, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authPath.path)
        }
        return updated
    }

    // MARK: - Response parsing

    private struct Response: Decodable {
        struct Window: Decodable {
            let used_percent: Double?
            let limit_window_seconds: Int?
            let reset_after_seconds: Double?
            let reset_at: Double?
        }
        struct RateLimit: Decodable {
            let primary_window: Window?
            let secondary_window: Window?
        }
        struct Additional: Decodable {
            let limit_name: String?
            let rate_limit: RateLimit?
        }
        struct Credits: Decodable {
            let unlimited: Bool?
            let balance: String?
            let has_credits: Bool?
        }
        let plan_type: String?
        let rate_limit: RateLimit?
        let additional_rate_limits: [Additional]?
        let credits: Credits?
    }

    private func parse(_ data: Data) throws -> ProviderSnapshot {
        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ProviderError.decoding(error.localizedDescription)
        }

        var windows: [UsageWindow] = []

        func append(_ window: Response.Window?, id: String, label: String, primary: Bool, group: String? = nil) {
            guard let window, let percent = window.used_percent else { return }
            windows.append(UsageWindow(
                id: id,
                label: label,
                usedPercent: min(100, max(0, percent)),
                resetsAt: Self.resetDate(window),
                windowSeconds: window.limit_window_seconds,
                isPrimary: primary,
                group: group
            ))
        }

        // The main quota drives the gauge; per-model caps are listed beneath it.
        append(decoded.rate_limit?.primary_window,
               id: "primary",
               label: Self.windowLabel(decoded.rate_limit?.primary_window,
                                       fallback: L10n.t("window.codex.mainLimit", "Main limit")),
               primary: true)

        for (index, extra) in (decoded.additional_rate_limits ?? []).enumerated() {
            let name = extra.limit_name ?? L10n.f("window.codex.extraLimit", "Extra limit %d", index + 1)
            append(extra.rate_limit?.primary_window,
                   id: "extra-\(index)-primary",
                   label: Self.windowLabel(extra.rate_limit?.primary_window,
                                          fallback: L10n.t("window.codex.primary", "Primary")),
                   primary: false,
                   group: name)
            append(extra.rate_limit?.secondary_window,
                   id: "extra-\(index)-secondary",
                   label: Self.windowLabel(extra.rate_limit?.secondary_window,
                                          fallback: L10n.t("window.codex.secondary", "Secondary")),
                   primary: false,
                   group: name)
        }

        guard !windows.isEmpty else {
            throw ProviderError.decoding(L10n.t(
                "error.codex.noUsageFields",
                "No usage fields found — see codex-usage.json in the debug logs"
            ))
        }

        var notes: [String] = []
        if let credits = decoded.credits {
            if credits.unlimited == true {
                notes.append(L10n.t("note.credits.unlimited", "Credits: unlimited"))
            } else if let balance = credits.balance {
                notes.append(L10n.f("note.credits.balance", "Credit balance: %@", "\(balance)"))
            }
        }

        return ProviderSnapshot(
            providerID: id,
            displayName: displayName,
            shortTag: shortTag,
            planLabel: decoded.plan_type,
            windows: windows,
            fetchedAt: Date(),
            notes: notes
        )
    }

    private static func resetDate(_ window: Response.Window) -> Date? {
        if let at = window.reset_at { return Date(timeIntervalSince1970: at) }
        if let after = window.reset_after_seconds { return Date().addingTimeInterval(after) }
        return nil
    }

    /// The API names windows only by duration, so derive a readable label.
    private static func windowLabel(_ window: Response.Window?, fallback: String) -> String {
        guard let seconds = window?.limit_window_seconds else { return fallback }
        switch seconds {
        case 3600: return L10n.t("window.hour1", "1-hour window")
        case 18000: return L10n.t("window.hour5", "5-hour window")
        case 86400: return L10n.t("window.hour24", "24-hour window")
        case 604800: return L10n.t("window.day7", "7-day window")
        default:
            if seconds % 86400 == 0 { return L10n.f("window.daysN", "%d-day window", seconds / 86400) }
            if seconds % 3600 == 0 { return L10n.f("window.hoursN", "%d-hour window", seconds / 3600) }
            return L10n.f("window.secondsN", "%d-second window", seconds)
        }
    }
}
