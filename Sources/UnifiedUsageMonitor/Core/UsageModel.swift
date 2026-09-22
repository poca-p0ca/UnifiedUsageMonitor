import Foundation

/// One metered window reported by a provider (e.g. Claude's 5-hour session cap,
/// or Codex's 7-day quota).
struct UsageWindow: Identifiable, Equatable {
    let id: String
    /// Human label shown in the popover, e.g. "5-hour session". Providers
    /// localize these before constructing the window.
    let label: String
    /// 0...100. Providers report integers; we keep a Double for smoother bars.
    let usedPercent: Double
    /// Absolute wall-clock reset time, when the provider tells us one.
    let resetsAt: Date?
    /// Length of the window in seconds, used only for display ("7-day window").
    let windowSeconds: Int?
    /// Marks the window that should drive the menu bar summary for its provider.
    let isPrimary: Bool
    /// Optional heading for windows that belong together, such as the several
    /// windows of one per-model quota. Declared last so existing call sites
    /// that omit it keep compiling.
    var group: String? = nil

    var remainingPercent: Double { max(0, 100 - usedPercent) }

    var severity: Severity {
        switch usedPercent {
        case ..<60: return .ok
        case ..<85: return .warning
        case ..<100: return .critical
        default: return .exhausted
        }
    }

    enum Severity { case ok, warning, critical, exhausted }
}

/// A provider's whole answer for one refresh cycle.
struct ProviderSnapshot: Equatable {
    let providerID: String
    let displayName: String
    /// Short tag used in the menu bar, e.g. "CL".
    let shortTag: String
    let planLabel: String?
    let windows: [UsageWindow]
    let fetchedAt: Date
    /// Extra lines the provider wants to show verbatim (credits, model gates…).
    let notes: [String]

    var primaryWindow: UsageWindow? {
        windows.first(where: { $0.isPrimary }) ?? windows.first
    }
}

/// What the UI renders for one provider: either data, an error, or "not set up".
enum ProviderState: Equatable {
    case idle
    case loading
    case loaded(ProviderSnapshot)
    /// The last good reading, kept on screen after a later fetch failed.
    /// Blanking a gauge that was right a few minutes ago reads as the app being
    /// broken; a desaturated last value with its time and the reason does not.
    case stale(ProviderSnapshot, message: String)
    case unavailable(reason: String)
    case failed(message: String)

    var snapshot: ProviderSnapshot? {
        switch self {
        case .loaded(let snapshot), .stale(let snapshot, _): return snapshot
        default: return nil
        }
    }
}

/// Errors a provider can raise. `unavailable` means "nothing to configure here,
/// stop retrying"; everything else is a transient failure worth showing.
enum ProviderError: LocalizedError {
    case notConfigured(String)
    case authExpired(String)
    /// The stored credential has lapsed and nothing was attempted over the
    /// network — distinct from `authExpired`, which means a server refused us.
    /// Whoever owns the credential refreshes it on their own schedule, so the
    /// only useful response is to look again on the next poll.
    case credentialsStale(String)
    case rateLimited(retryAfter: TimeInterval?)
    case http(status: Int, body: String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let s): return s
        case .authExpired(let s): return s
        case .credentialsStale(let s): return s
        case .rateLimited(let retry):
            if let retry {
                return L10n.f("error.rateLimited.retryIn", "Rate limited — retrying in %ds", Int(retry))
            }
            return L10n.t("error.rateLimited", "Rate limited — retrying shortly")
        case .http(let status, let body):
            let trimmed = body.prefix(200)
            return "HTTP \(status)\(trimmed.isEmpty ? "" : " — \(trimmed)")"
        case .decoding(let s):
            return L10n.f("error.decoding", "Could not read the response — %@", s)
        }
    }
}

protocol UsageProvider: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var shortTag: String { get }
    /// Minimum seconds between network calls. The scheduler never polls faster.
    var minimumInterval: TimeInterval { get }

    /// Whether this tool is present on the machine. Must be cheap and do no
    /// networking: it runs on every scheduler tick so a tool installed later
    /// shows up without restarting the app.
    ///
    /// This tests for *installation*, not login. A tool that is installed but
    /// signed out still gets a gauge, showing what to do about it, which is
    /// more useful than silently omitting it.
    func isInstalled() -> Bool

    /// Whether reading this tool's credentials can raise the macOS "allow
    /// access" dialog — true when the credential lives in a keychain item
    /// another app owns. First-run onboarding uses it to say, before any of it
    /// happens, which tools are about to ask and why.
    var promptsForKeychainAccess: Bool { get }

    func fetch() async throws -> ProviderSnapshot
}

extension UsageProvider {
    /// Credentials kept in a plain file raise nothing.
    var promptsForKeychainAccess: Bool { false }
}
