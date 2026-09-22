import Foundation
import Combine

/// Owns every provider, the poll schedule, and the state the UI observes.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var states: [String: ProviderState] = [:]
    /// Providers detected on this machine, in configured order. The UI renders
    /// exactly these, so a machine with only one tool shows one gauge.
    @Published private(set) var providers: [UsageProvider] = []
    @Published private(set) var lastRefresh: Date?
    @Published var isRefreshing = false

    /// Everything this build knows how to read, installed or not.
    private let allProviders: [UsageProvider]

    /// How often the timer ticks. Each provider still enforces its own
    /// `minimumInterval`, so a fast tick does not mean a fast request.
    private let tickInterval: TimeInterval = 30
    private var timer: Timer?
    private var lastAttempt: [String: Date] = [:]
    /// Set when a provider 429s, to hold it off past the retry hint.
    private var backoffUntil: [String: Date] = [:]
    /// Preview stores skip detection so stub providers stay visible.
    private let detects: Bool

    init(providers: [UsageProvider]) {
        self.allProviders = providers
        self.detects = true
    }

    /// Builds a store with fixed state and no polling, for offscreen snapshots.
    init(previewProviders: [UsageProvider], states: [String: ProviderState]) {
        self.allProviders = previewProviders
        self.providers = previewProviders
        self.states = states
        self.detects = false
        self.lastRefresh = Date()
    }

    /// Detected tools for the first-run window, without starting the poll
    /// loop. Safe before onboarding: `isInstalled()` reads keychain attributes
    /// and file paths only, so nothing here can raise an access prompt.
    func detectedTools() -> [(name: String, promptsForKeychain: Bool)] {
        allProviders
            .filter { $0.isInstalled() }
            .map { ($0.displayName, $0.promptsForKeychainAccess) }
    }

    func start() {
        detectInstalled()
        refresh(force: true)
        let timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.detectInstalled()
                self?.refresh(force: false)
            }
        }
        timer.tolerance = 5
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Re-run on every tick, not just at launch: installing or logging into a
    /// tool should make its gauge appear without restarting the app.
    private func detectInstalled() {
        guard detects else { return }
        let installed = allProviders.filter { $0.isInstalled() }
        guard installed.map(\.id) != providers.map(\.id) else { return }

        providers = installed
        let live = Set(installed.map(\.id))
        states = states.filter { live.contains($0.key) }
        for provider in installed where states[provider.id] == nil {
            states[provider.id] = .idle
        }
        DebugLog.note("detected: \(installed.map(\.id).joined(separator: ", "))")
    }

    /// `force` bypasses the interval check but never the backoff — a manual
    /// click during a 429 would only deepen the block.
    func refresh(force: Bool) {
        let now = Date()
        var launched = false

        for provider in providers {
            if let until = backoffUntil[provider.id], until > now { continue }
            if !force, let last = lastAttempt[provider.id],
               now.timeIntervalSince(last) < provider.minimumInterval { continue }

            lastAttempt[provider.id] = now
            launched = true
            if states[provider.id]?.snapshot == nil {
                states[provider.id] = .loading
            }
            Task { await self.load(provider) }
        }

        if launched { isRefreshing = true }
    }

    private func load(_ provider: UsageProvider) async {
        do {
            let snapshot = try await provider.fetch()
            states[provider.id] = .loaded(snapshot)
            backoffUntil[provider.id] = nil
            lastRefresh = Date()
        } catch let error as ProviderError {
            switch error {
            case .notConfigured(let reason):
                states[provider.id] = .unavailable(reason: reason)
                // Nothing to poll for until the user logs in somewhere else.
                backoffUntil[provider.id] = Date().addingTimeInterval(600)
            case .authExpired(let reason):
                // Usually a rejected token refresh. Retrying on every poll would
                // only repeat the same doomed request against the token endpoint.
                backoffUntil[provider.id] = Date().addingTimeInterval(provider.minimumInterval * 2)
                markFailed(provider, message: reason)
            case .credentialsStale(let reason):
                // No backoff on purpose: the check costs a keychain read and no
                // network call, and the credential is usually valid again well
                // inside one poll interval.
                markFailed(provider, message: reason)
            case .rateLimited(let retryAfter):
                // The Anthropic endpoint punishes retries, so back off long.
                let delay = max(retryAfter ?? 0, provider.minimumInterval * 4)
                backoffUntil[provider.id] = Date().addingTimeInterval(delay)
                markFailed(provider, message: error.localizedDescription)
            default:
                markFailed(provider, message: error.localizedDescription)
            }
            DebugLog.note("\(provider.id): \(error.localizedDescription)")
        } catch {
            markFailed(provider, message: error.localizedDescription)
            DebugLog.note("\(provider.id): \(error.localizedDescription)")
        }

        isRefreshing = providers.contains { states[$0.id] == .loading }
    }

    /// Keeps the last good snapshot visible when there is one. Signed-out
    /// providers go through `.unavailable` instead: their old numbers would
    /// describe an account that is no longer connected.
    private func markFailed(_ provider: UsageProvider, message: String) {
        if let previous = states[provider.id]?.snapshot {
            states[provider.id] = .stale(previous, message: message)
        } else {
            states[provider.id] = .failed(message: message)
        }
    }

    /// Ordered snapshots for the menu bar summary, providers in config order.
    var summaries: [(provider: UsageProvider, state: ProviderState)] {
        providers.map { ($0, states[$0.id] ?? .idle) }
    }
}
