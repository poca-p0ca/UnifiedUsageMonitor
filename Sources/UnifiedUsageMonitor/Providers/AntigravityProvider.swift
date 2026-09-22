import Foundation

/// Reads Antigravity's weekly quota from the Code Assist internal API, the same
/// pair of calls the CLI's own quota manager makes: `loadCodeAssist` to learn
/// which project the account belongs to, then `retrieveUserQuotaSummary`.
///
/// This one reports `remainingFraction` directly, which is what the gauges show
/// anyway — no conversion from a "used" figure.
final class AntigravityProvider: UsageProvider {
    let id = "antigravity"
    let displayName = "Antigravity"
    let shortTag = "AG"
    let minimumInterval: TimeInterval = 300

    let promptsForKeychainAccess = true

    /// The CLI writes its token under the "gemini" service, keyed by account.
    private let keychainService = "gemini"
    private let keychainAccount = "antigravity"

    /// This app's own copy of the refresh token. The CLI's item belongs to the
    /// CLI, so reading it prompts for the keychain password whenever this app
    /// is not on its ACL; an item this app creates has no such problem. Safe to
    /// copy precisely because Google does not rotate this refresh token, so the
    /// copy cannot drift from the CLI's and cannot invalidate it.
    private let ownService = Keychain.ownService
    private let ownAccount = "antigravity-refresh"

    /// The CLI itself talks to `daily-cloudcode-pa`, a staging host. Production
    /// answers identically and is the safer dependency.
    private let host = "https://cloudcode-pa.googleapis.com"
    private let userAgent = "antigravity-cli"

    /// The account's project does not change between polls, so it is resolved
    /// once and reused; a failed quota call clears it in case it went stale.
    private var cachedProject: String?

    private let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    /// Antigravity's OAuth clients come from `AntigravityClients`, which reads
    /// them out of the installed CLI binary. They are Google's credentials, not
    /// this project's, so no copy is kept in the repository — and a CLI release
    /// that adds or rotates a client is picked up without a new build here.
    ///
    /// There is more than one, and the stored token can come from either: a
    /// CLI update that re-authenticated a different account moved it from one
    /// to the other. Presenting a refresh token with the wrong client is
    /// refused as `unauthorized_client`, so the issuing client is read from the
    /// token's own `id_token` instead of being assumed.

    /// A refreshed access token, held only in memory. Google does not rotate
    /// the refresh token on these clients, so nothing needs writing back to the
    /// keychain — which keeps this app incapable of disturbing the CLI's login.
    ///
    /// The CLI renews the stored token only while it runs, so with the CLI
    /// closed this is what keeps the gauge alive, at about one refresh an hour.
    private var refreshedToken: (value: String, expiry: Date)?

    func isInstalled() -> Bool {
        Keychain.exists(service: keychainService, account: keychainAccount)
            || Installed.anyExists([".gemini/antigravity-cli", ".antigravity"])
    }

    func fetch() async throws -> ProviderSnapshot {
        let token = try await loadAccessToken()
        let project = try await resolveProject(token: token)

        do {
            let body = try await post(
                method: "retrieveUserQuotaSummary",
                token: token,
                payload: ["project": project]
            )
            DebugLog.dump(body, name: "antigravity-usage")
            return try parse(body)
        } catch {
            cachedProject = nil
            throw error
        }
    }

    // MARK: - Credentials

    /// The Go keyring library stores values base64-encoded behind a marker.
    private static let keyringPrefix = "go-keyring-base64:"

    private func loadAccessToken() async throws -> String {
        if let cached = refreshedToken, cached.expiry.timeIntervalSinceNow > 60, !forcesRefresh {
            return cached.value
        }

        // Own copy first: this is the whole point of keeping one. A revoked or
        // superseded token simply fails here and falls through to the CLI's
        // item, which also repairs the copy.
        // The stored secret is what makes this path independent of the CLI
        // binary: once one client is known to work, refreshing needs no scan
        // and keeps working even if the CLI is moved or removed.
        if let mine = ownCopy(),
           let token = try? await renew(using: mine.refreshToken,
                                        issuer: mine.clientID,
                                        secret: mine.clientSecret) {
            return token
        }

        let raw: String
        do {
            raw = try Keychain.readString(service: keychainService, account: keychainAccount)
        } catch let error as Keychain.KeychainError where error.isMissing {
            throw ProviderError.notConfigured(L10n.t("error.antigravity.login", "Sign in with the Antigravity CLI"))
        }

        guard raw.hasPrefix(Self.keyringPrefix),
              let decoded = Data(base64Encoded: String(raw.dropFirst(Self.keyringPrefix.count))),
              let root = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any],
              let token = root["token"] as? [String: Any],
              let access = token["access_token"] as? String
        else {
            throw ProviderError.notConfigured(L10n.t(
                "error.antigravity.malformed",
                "Malformed credentials — sign in to the Antigravity CLI again"
            ))
        }

        let issuer = Self.issuingClient(of: root["id_token"] as? String)
        if let refresh = token["refresh_token"] as? String {
            storeOwnCopy(refreshToken: refresh, clientID: issuer)
        }

        // A minute of headroom so a slow request cannot outlive its token.
        let stored = Timestamp.parse(token["expiry"])
        if (stored?.timeIntervalSinceNow ?? 0) > 60, !forcesRefresh {
            refreshedToken = nil
            return access
        }

        guard let refresh = token["refresh_token"] as? String else {
            throw ProviderError.authExpired(L10n.t(
                "error.antigravity.expired",
                "Token expired — sign in to the Antigravity CLI again"
            ))
        }
        return try await renew(using: refresh, issuer: issuer)
    }

    private struct OwnCopy {
        let refreshToken: String
        let clientID: String?
        /// Cached after a refresh succeeds, so later refreshes skip the scan.
        /// The keychain is the only place this app persists it.
        let clientSecret: String?
    }

    private func ownCopy() -> OwnCopy? {
        guard let raw = try? Keychain.readString(service: ownService, account: ownAccount),
              let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let refresh = json["refresh_token"] as? String
        else { return nil }
        return OwnCopy(refreshToken: refresh,
                       clientID: json["client_id"] as? String,
                       clientSecret: json["client_secret"] as? String)
    }

    private func storeOwnCopy(refreshToken: String, clientID: String?) {
        // A known-good secret outlives a re-read of the CLI item, so it is kept
        // when only the issuer claim is being recorded.
        let existing = ownCopy()
        if let existing, existing.refreshToken == refreshToken, existing.clientID == clientID { return }
        let secret = (existing?.clientID == clientID) ? existing?.clientSecret : nil
        writeOwnCopy(refreshToken: refreshToken, clientID: clientID, clientSecret: secret,
                     note: "refresh token copied to this app's own keychain item")
    }

    private func writeOwnCopy(refreshToken: String, clientID: String?, clientSecret: String?, note: String) {
        var json: [String: Any] = ["refresh_token": refreshToken]
        if let clientID { json["client_id"] = clientID }
        if let clientSecret { json["client_secret"] = clientSecret }
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8)
        else { return }

        do {
            try Keychain.upsert(text, service: ownService, account: ownAccount)
            DebugLog.note("antigravity: \(note)")
        } catch {
            DebugLog.note("antigravity: could not store own copy — \(error.localizedDescription)")
        }
    }

    /// Debug hook for exercising the refresh path while the stored token is
    /// still valid.
    private var forcesRefresh: Bool {
        ProcessInfo.processInfo.environment["UUM_ANTIGRAVITY_FORCE_REFRESH"] == "1"
    }

    /// Orders the clients to try: a secret already known to work first, then
    /// whichever discovered client the token's `id_token` names, then the rest.
    ///
    /// Trying more than one is not sloppiness — the CLI ships several clients,
    /// and pairing an ID to its secret inside a stripped binary is a proximity
    /// guess. One wrong attempt costs a rejected token request; getting it
    /// wrong permanently would cost the gauge.
    private func clientCandidates(issuer: String?,
                                  knownSecret: String?) throws -> [AntigravityClients.Client] {
        var candidates: [AntigravityClients.Client] = []
        if let issuer, let knownSecret {
            candidates.append(AntigravityClients.Client(id: issuer, secret: knownSecret))
        }

        let discovered = AntigravityClients.discover()
        let matching = discovered.filter { $0.id == issuer }
        if let issuer, !discovered.isEmpty, matching.isEmpty {
            // Most likely a CLI update introduced an OAuth client this scan did
            // not recognise; the others are still worth trying.
            DebugLog.note("antigravity: token issued by client \(issuer), which the CLI scan did not find")
        }
        candidates += matching + discovered.filter { !matching.contains($0) }

        var seen = Set<String>()
        candidates = candidates.filter { seen.insert($0.id + $0.secret).inserted }

        guard !candidates.isEmpty else {
            // No stored secret and no CLI to read one from. Saying so beats a
            // generic auth failure: the fix is to install or keep the CLI.
            DebugLog.note("antigravity: no OAuth client available; CLI binary not found")
            throw ProviderError.notConfigured(L10n.t(
                "error.antigravity.noClient",
                "Antigravity CLI not found — it is needed to refresh the token"
            ))
        }
        return candidates
    }

    private func renew(using refreshToken: String,
                       issuer: String?,
                       secret: String? = nil) async throws -> String {
        let candidates = try clientCandidates(issuer: issuer, knownSecret: secret)

        for client in candidates {
            var request = URLRequest(url: tokenURL)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

            var form = URLComponents()
            form.queryItems = [
                URLQueryItem(name: "client_id", value: client.id),
                URLQueryItem(name: "client_secret", value: client.secret),
                URLQueryItem(name: "refresh_token", value: refreshToken),
                URLQueryItem(name: "grant_type", value: "refresh_token"),
            ]
            request.httpBody = form.percentEncodedQuery.map { Data($0.utf8) }

            let (status, body, _) = try await HTTP.send(request)
            if status == 200,
               let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let access = payload["access_token"] as? String {
                let lifetime = Timestamp.number(payload["expires_in"]) ?? 3600
                refreshedToken = (access, Date().addingTimeInterval(lifetime))
                DebugLog.note("antigravity: access token refreshed via \(client.id.prefix(13)) (\(Int(lifetime))s)")
                // Remember which client worked, so the next refresh needs
                // neither the CLI binary nor a guess.
                if ownCopy()?.clientSecret != client.secret || ownCopy()?.clientID != client.id {
                    writeOwnCopy(refreshToken: refreshToken,
                                 clientID: client.id,
                                 clientSecret: client.secret,
                                 note: "working OAuth client recorded for future refreshes")
                }
                return access
            }

            DebugLog.dump(body, name: "antigravity-token-error")
            DebugLog.note("antigravity token refresh via \(client.id.prefix(13)) HTTP \(status): \(HTTP.text(body).prefix(160))")
        }

        // With the right client this means the refresh token itself was
        // revoked or expired, which only a new login fixes. A wrong client
        // shows up as `unauthorized_client` in the note above.
        throw ProviderError.authExpired(L10n.t(
            "error.antigravity.refreshFailed",
            "Token refresh failed — sign in to the Antigravity CLI again"
        ))
    }

    /// The OAuth client a token was issued to, from its `id_token` payload.
    /// The signature is not checked: the value only picks which client to
    /// present, and a wrong pick simply fails the refresh.
    private static func issuingClient(of idToken: String?) -> String? {
        guard let parts = idToken?.split(separator: "."), parts.count >= 2 else { return nil }
        var payload = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)

        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let azp = claims["azp"] as? String { return azp }
        if let aud = claims["aud"] as? String { return aud }
        return (claims["aud"] as? [String])?.first
    }

    // MARK: - Requests

    private func resolveProject(token: String) async throws -> String {
        if let cachedProject { return cachedProject }

        let body = try await post(method: "loadCodeAssist", token: token, payload: [:])
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let project = root["cloudaicompanionProject"] as? String
        else {
            throw ProviderError.decoding(L10n.t("error.antigravity.noProject", "No project in the loadCodeAssist response"))
        }
        cachedProject = project
        return project
    }

    private func post(method: String, token: String, payload: [String: Any]) async throws -> Data {
        var request = URLRequest(url: URL(string: "\(host)/v1internal:\(method)")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (status, body, headers) = try await HTTP.send(request)
        switch status {
        case 200:
            return body
        case 401, 403:
            DebugLog.note("antigravity \(method) HTTP \(status): \(HTTP.text(body).prefix(200))")
            throw ProviderError.authExpired(L10n.t("error.antigravity.relogin", "Sign in to the Antigravity CLI again"))
        case 429:
            throw ProviderError.rateLimited(retryAfter: HTTP.retryAfter(from: headers))
        default:
            throw ProviderError.http(status: status, body: HTTP.text(body))
        }
    }

    // MARK: - Response parsing

    private struct Response: Decodable {
        struct Bucket: Decodable {
            let bucketId: String?
            let displayName: String?
            /// "weekly", "5h" — shorter and more stable than `displayName`,
            /// which reads "Five Hour Limit Remaining" and would not fit.
            let window: String?
            let resetTime: String?
            let remainingFraction: Double?
        }
        struct Group: Decodable {
            let displayName: String?
            let buckets: [Bucket]?
        }
        let groups: [Group]?
    }

    private func parse(_ data: Data) throws -> ProviderSnapshot {
        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ProviderError.decoding(error.localizedDescription)
        }

        var windows: [UsageWindow] = []
        for (groupIndex, group) in (decoded.groups ?? []).enumerated() {
            let name = Self.shorten(group.displayName ?? L10n.f("window.antigravity.group", "Group %d", groupIndex + 1))
            let buckets = group.buckets ?? []

            for (bucketIndex, bucket) in buckets.enumerated() {
                guard let remaining = bucket.remainingFraction else { continue }
                // A group usually has several windows; name each one so the
                // rows stay distinguishable at column width.
                let label = buckets.count > 1
                    ? "\(name) \(Self.windowLabel(bucket, index: bucketIndex))"
                    : name
                windows.append(UsageWindow(
                    id: bucket.bucketId ?? "group-\(groupIndex)-\(bucketIndex)",
                    label: label,
                    usedPercent: min(100, max(0, (1 - remaining) * 100)),
                    resetsAt: Timestamp.parse(bucket.resetTime),
                    windowSeconds: nil,
                    isPrimary: false
                ))
            }
        }

        guard !windows.isEmpty else {
            throw ProviderError.decoding(L10n.t("error.antigravity.emptyGroups", "Quota groups are empty"))
        }

        // The groups are peers rather than a session-plus-extras arrangement,
        // so the gauge shows whichever will run out first.
        let tightest = windows.enumerated().max { $0.element.usedPercent < $1.element.usedPercent }
        if let tightest {
            let window = tightest.element
            windows[tightest.offset] = UsageWindow(
                id: window.id,
                label: window.label,
                usedPercent: window.usedPercent,
                resetsAt: window.resetsAt,
                windowSeconds: window.windowSeconds,
                isPrimary: true,
                group: window.group
            )
            windows.insert(windows.remove(at: tightest.offset), at: 0)
        }

        return ProviderSnapshot(
            providerID: id,
            displayName: displayName,
            shortTag: shortTag,
            planLabel: nil,
            windows: windows,
            fetchedAt: Date(),
            notes: []
        )
    }

    private static func windowLabel(_ bucket: Response.Bucket, index: Int) -> String {
        switch bucket.window {
        case "weekly": return L10n.t("window.antigravity.weekly", "7d")
        case "5h": return L10n.t("window.antigravity.5h", "5h")
        case let other?: return other
        case nil: return bucket.displayName ?? L10n.f("window.antigravity.limit", "Limit %d", index + 1)
        }
    }

    /// "Gemini Models" and "Claude and GPT models" overflow a gauge column.
    /// The trailing noun adds nothing next to a quota reading, and the
    /// conjunction costs more width than the separator it becomes.
    /// Turns Google's group name into something that fits a gauge column.
    ///
    /// "Claude and GPT models" became "Claude · GPT", which still overran the
    /// column and truncated mid-word once a window name was appended. The
    /// group is simply the non-Gemini pool, so it is named for what it is
    /// rather than listing its members — which also survives Google adding a
    /// third vendor to it.
    private static func shorten(_ name: String) -> String {
        let lowered = name.lowercased()
        if lowered.contains("claude") || lowered.contains("gpt") {
            return L10n.t("window.antigravity.thirdParty", "Other models")
        }

        var result = name
        for suffix in [" models", " Models"] where result.hasSuffix(suffix) {
            result = String(result.dropLast(suffix.count))
        }
        return result.replacingOccurrences(of: " and ", with: " · ")
    }
}
