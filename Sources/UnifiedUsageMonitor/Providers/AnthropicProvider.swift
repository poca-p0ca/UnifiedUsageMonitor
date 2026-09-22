import Foundation

/// Reads Claude subscription usage from the endpoint Claude Code's own `/usage`
/// command uses. It is first-party but undocumented, so the response decoder
/// below is deliberately shape-tolerant.
///
/// Usage on claude.ai, Claude Desktop and Claude Code all draw from one pool,
/// so this reflects web activity even if Claude Code is never opened.
final class AnthropicProvider: UsageProvider {
    let id = "anthropic"
    let displayName = "Claude"
    let shortTag = "CL"

    /// The endpoint 429s hard and the block persists for hours. Claude Code
    /// itself is safe at 180s; we stay well clear of that.
    let minimumInterval: TimeInterval = 300

    let promptsForKeychainAccess = true

    private let keychainService = "Claude Code-credentials"
    private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let tokenURL = URL(string: "https://api.anthropic.com/v1/oauth/token")!
    /// Claude Code's own OAuth client. A public identifier with no secret.
    private let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    /// Sending a real claude-code User-Agent is not cosmetic: without it the
    /// request lands in a much tighter rate-limit bucket. The version is read
    /// from the installed CLI rather than hardcoded, so it does not go stale.
    private var userAgent: String {
        let version = Installed.claudeCodeVersion() ?? "2.1.81"
        return "claude-code/\(version) (external, cli)"
    }

    func isInstalled() -> Bool {
        // `~/.claude` is created on first run whatever the install method
        // (native, Homebrew, npm), so it catches an installed-but-never-signed-in
        // CLI that the keychain check alone would miss.
        Keychain.exists(service: keychainService)
            || Installed.anyExists([".claude", ".local/share/claude", ".local/bin/claude"])
    }

    func fetch() async throws -> ProviderSnapshot {
        let creds = try credentials()
        let token = try await validAccessToken(for: creds)

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (status, body, headers) = try await HTTP.send(request)
        DebugLog.dump(body, name: "anthropic-usage")

        switch status {
        case 200:
            return try parse(body)
        case 401:
            cachedCredentials = nil
            throw ProviderError.authExpired(L10n.t("error.claude.relogin", "Signed out — run `claude` in a terminal and sign in"))
        case 429:
            throw ProviderError.rateLimited(retryAfter: HTTP.retryAfter(from: headers))
        default:
            throw ProviderError.http(status: status, body: HTTP.text(body))
        }
    }

    // MARK: - Credentials

    /// Parsed credentials kept in memory. Every read of Claude Code's keychain
    /// item can raise the "allow access" prompt — the item belongs to Claude
    /// Code, so this app cannot put itself on its ACL for good — and the poll
    /// loop used to read it twice per cycle. Now it is read once and reused
    /// until the access token is nearly expired.
    private var cachedCredentials: Credentials?

    private func credentials() throws -> Credentials {
        if let cached = cachedCredentials, let expiry = cached.expiresAt,
           expiry.timeIntervalSinceNow > 60 {
            return cached
        }
        let fresh = try readCredentials()
        cachedCredentials = fresh
        return fresh
    }

    private struct Credentials {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date?
        /// When the refresh token itself dies. Past this, no amount of running
        /// the CLI helps — it has to be signed in again, and saying so is the
        /// difference between a fix that takes seconds and one the user cannot
        /// find.
        var refreshTokenExpiresAt: Date?
        var subscriptionType: String?
        /// The full keychain blob, so a refresh rewrites it without dropping
        /// fields this app does not understand.
        var raw: [String: Any]
    }

    private func readCredentials() throws -> Credentials {
        let text: String
        do {
            text = try Keychain.readString(service: keychainService)
        } catch let error as Keychain.KeychainError where error.isMissing {
            throw ProviderError.notConfigured(L10n.t("error.claude.login", "Sign in: run `claude` in a terminal"))
        }
        return try parseCredentials(text)
    }

    private func parseCredentials(_ text: String) throws -> Credentials {
        guard let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String,
              let refresh = oauth["refreshToken"] as? String
        else {
            throw ProviderError.notConfigured(L10n.t("error.claude.malformed", "Malformed credentials — sign in again"))
        }

        let millis = { (key: String) -> Date? in
            (oauth[key] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        }
        return Credentials(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: millis("expiresAt"),
            refreshTokenExpiresAt: millis("refreshTokenExpiresAt"),
            subscriptionType: oauth["subscriptionType"] as? String,
            raw: root
        )
    }

    /// Returns a usable access token, refreshing when the stored one has
    /// lapsed.
    ///
    /// This used to refuse to refresh, on the grounds that writing the rotated
    /// token back to Claude Code's keychain item would make macOS demand the
    /// keychain password every time. Measured, that does not happen: the write
    /// returns in about 30ms with no prompt. What the old behaviour cost was
    /// real — an access token lasts about eight hours, so anyone who did not
    /// run the CLI that day found an empty gauge, and a refresh token left
    /// unused for its full month died and forced a fresh sign-in.
    private func validAccessToken(for creds: Credentials) async throws -> String {
        if let expiry = creds.expiresAt, expiry.timeIntervalSinceNow > 60 {
            return creds.accessToken
        }

        // Once the refresh token is gone no request can recover the session.
        if let refreshExpiry = creds.refreshTokenExpiresAt, refreshExpiry.timeIntervalSinceNow <= 0 {
            throw ProviderError.credentialsStale(
                L10n.t("error.claude.relogin", "Signed out — run `claude` in a terminal and sign in")
            )
        }

        return try await refresh(creds)
    }

    /// Exchanges the refresh token and writes the result back to the keychain.
    ///
    /// Anthropic rotates the refresh token, so the response **must** reach the
    /// keychain — a rotated token we fail to store is a Claude Code login we
    /// just broke. Two things follow. The credential is re-read immediately
    /// beforehand, so a token the CLI rotated in the meantime is not replayed;
    /// and the whole blob is written back, not a rebuilt one, so fields this
    /// app does not model (`mcpOAuth`, for one) survive.
    private func refresh(_ stale: Credentials) async throws -> String {
        // The CLI may have refreshed since this copy was taken — that is the
        // common case, since it refreshes on every run.
        let creds = (try? readCredentials()) ?? stale
        if let expiry = creds.expiresAt, expiry.timeIntervalSinceNow > 60 {
            cachedCredentials = creds
            return creds.accessToken
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": creds.refreshToken,
            "client_id": clientID,
        ])

        let (status, body, _) = try await HTTP.send(request)
        guard status == 200,
              let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else {
            DebugLog.note("anthropic token refresh HTTP \(status): \(HTTP.text(body).prefix(160))")
            cachedCredentials = nil
            throw ProviderError.credentialsStale(
                L10n.t("error.claude.relogin", "Signed out — run `claude` in a terminal and sign in")
            )
        }

        // Read leniently. By this point the server has already rotated the
        // token, so failing to recognise its answer costs the user their CLI
        // login — the raw body goes to the log to make that diagnosable.
        let access = (payload["access_token"] ?? payload["accessToken"]) as? String
        guard let access else {
            DebugLog.dump(body, name: "anthropic-token-unrecognised")
            DebugLog.note("anthropic: refresh succeeded but no access token found; see anthropic-token-unrecognised.json")
            cachedCredentials = nil
            throw ProviderError.credentialsStale(
                L10n.t("error.claude.relogin", "Signed out — run `claude` in a terminal and sign in")
            )
        }

        var oauth = (creds.raw["claudeAiOauth"] as? [String: Any]) ?? [:]
        oauth["accessToken"] = access
        if let rotated = (payload["refresh_token"] ?? payload["refreshToken"]) as? String {
            oauth["refreshToken"] = rotated
        }
        if let lifetime = Timestamp.number(payload["expires_in"] ?? payload["expiresIn"]) {
            oauth["expiresAt"] = Date().addingTimeInterval(lifetime).timeIntervalSince1970 * 1000
        }
        if let refreshLifetime = Timestamp.number(payload["refresh_expires_in"]) {
            oauth["refreshTokenExpiresAt"] =
                Date().addingTimeInterval(refreshLifetime).timeIntervalSince1970 * 1000
        }

        var root = creds.raw
        root["claudeAiOauth"] = oauth
        guard let data = try? JSONSerialization.data(withJSONObject: root),
              let text = String(data: data, encoding: .utf8) else {
            DebugLog.note("anthropic: could not serialise the refreshed credential")
            throw ProviderError.credentialsStale(
                L10n.t("error.claude.relogin", "Signed out — run `claude` in a terminal and sign in")
            )
        }

        do {
            try Keychain.writeString(text, service: keychainService)
            DebugLog.note("anthropic: access token refreshed and written back")
        } catch {
            // The rotated token is now the only working one and it is not
            // stored. Say so loudly; the next run will need a sign-in.
            DebugLog.note("anthropic: refreshed but COULD NOT write back — \(error.localizedDescription)")
        }

        // Parsed from what was just written rather than read back: every read
        // of this item is one more chance at the "allow access" dialog.
        cachedCredentials = try? parseCredentials(text)
        return access
    }

    // MARK: - Response parsing

    /// Known window keys, in the order we want them displayed. Anything the
    /// endpoint adds later still shows up via the generic scan below.
    private static var knownWindows: [(key: String, label: String, primary: Bool)] {
        [
            ("five_hour", L10n.t("window.claude.session", "5h session"), true),
            ("seven_day", L10n.t("window.claude.weeklyAll", "7d · all models"), false),
            ("seven_day_opus", scopedWeekly("Opus"), false),
            ("seven_day_sonnet", scopedWeekly("Sonnet"), false),
        ]
    }

    private static func scopedWeekly(_ model: String) -> String {
        L10n.f("window.claude.weeklyScoped", "7d · %@", model)
    }

    private func parse(_ data: Data) throws -> ProviderSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.decoding(L10n.t("error.claude.notJSON", "Not a JSON object"))
        }

        // The windows may sit at the root or under a wrapper key depending on
        // the endpoint version, so search both.
        var containers: [[String: Any]] = [root]
        for key in ["usage", "rate_limits", "limits"] {
            if let nested = root[key] as? [String: Any] { containers.append(nested) }
        }

        // The `limits` array is the endpoint's own normalised view: it names
        // each window's kind and carries model-scoped weekly caps that have no
        // top-level key of their own. Prefer it, and keep the key scan below as
        // a fallback for older or future response shapes.
        var windows = Self.windowsFromLimits(root)
        var seen = Set<String>()

        for container in containers where windows.isEmpty {
            for (key, label, primary) in Self.knownWindows {
                guard !seen.contains(key), let raw = container[key] as? [String: Any] else { continue }
                guard let window = Self.makeWindow(id: key, label: label, primary: primary, from: raw) else { continue }
                seen.insert(key)
                windows.append(window)
            }
        }

        // Last resort: any remaining dictionary that carries a percentage.
        if windows.isEmpty {
            for container in containers {
                for (key, value) in container {
                    guard let raw = value as? [String: Any], !seen.contains(key) else { continue }
                    guard let window = Self.makeWindow(id: key, label: Self.prettify(key), primary: windows.isEmpty, from: raw) else { continue }
                    seen.insert(key)
                    windows.append(window)
                }
            }
        }

        guard !windows.isEmpty else {
            throw ProviderError.decoding(L10n.t(
                "error.claude.noUsageFields",
                "No usage fields found — see anthropic-usage.json in the debug logs"
            ))
        }

        let plan = (root["subscription_type"] as? String)
            ?? (root["plan"] as? String)
            ?? cachedCredentials?.subscriptionType

        return ProviderSnapshot(
            providerID: id,
            displayName: displayName,
            shortTag: shortTag,
            planLabel: (plan?.isEmpty == false) ? plan : nil,
            windows: windows,
            fetchedAt: Date(),
            notes: []
        )
    }

    /// Reads the `limits` array. Entries look like
    /// `{kind, percent, resets_at, scope: {model: {display_name}}}`.
    private static func windowsFromLimits(_ root: [String: Any]) -> [UsageWindow] {
        guard let entries = root["limits"] as? [[String: Any]] else { return [] }

        var windows: [UsageWindow] = []
        for (index, entry) in entries.enumerated() {
            guard let percent = Timestamp.number(entry["percent"]) else { continue }
            let kind = entry["kind"] as? String ?? "limit-\(index)"
            let scope = ((entry["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String

            windows.append(UsageWindow(
                id: scope.map { "\(kind)-\($0)" } ?? kind,
                label: limitLabel(kind: kind, scope: scope),
                usedPercent: min(100, max(0, percent)),
                resetsAt: Timestamp.parse(entry["resets_at"]),
                windowSeconds: nil,
                isPrimary: kind == "session"
            ))
        }

        // The session window drives the gauge. If the server ever stops
        // sending one, promote the first entry so the gauge is never blank.
        if !windows.isEmpty, !windows.contains(where: { $0.isPrimary }) {
            let first = windows[0]
            windows[0] = UsageWindow(id: first.id, label: first.label,
                                     usedPercent: first.usedPercent,
                                     resetsAt: first.resetsAt,
                                     windowSeconds: first.windowSeconds,
                                     isPrimary: true,
                                     group: first.group)
        }
        return windows.sorted { $0.isPrimary && !$1.isPrimary }
    }

    private static func limitLabel(kind: String, scope: String?) -> String {
        switch kind {
        case "session": return L10n.t("window.claude.session", "5h session")
        case "weekly_all": return L10n.t("window.claude.weeklyAll", "7d · all models")
        case "weekly_scoped":
            return scopedWeekly(scope ?? L10n.t("window.claude.someModels", "some models"))
        default: return scope.map { "\(prettify(kind)) · \($0)" } ?? prettify(kind)
        }
    }

    private static func makeWindow(id: String, label: String, primary: Bool, from raw: [String: Any]) -> UsageWindow? {
        let percentKeys = ["utilization", "used_percent", "usedPercent", "percent_used", "percentUsed"]
        guard let percent = percentKeys.lazy.compactMap({ Timestamp.number(raw[$0]) }).first else { return nil }

        var resetsAt: Date?
        for key in ["resets_at", "reset_at", "resetsAt", "resetAt"] {
            if let date = Timestamp.parse(raw[key]) { resetsAt = date; break }
        }
        if resetsAt == nil, let after = Timestamp.number(raw["reset_after_seconds"]) {
            resetsAt = Date().addingTimeInterval(after)
        }

        let windowSeconds = Timestamp.number(raw["limit_window_seconds"]).map { Int($0) }

        return UsageWindow(
            id: id,
            label: label,
            usedPercent: min(100, max(0, percent)),
            resetsAt: resetsAt,
            windowSeconds: windowSeconds,
            isPrimary: primary
        )
    }

    private static func prettify(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
