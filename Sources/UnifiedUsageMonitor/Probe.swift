import Foundation

/// `UnifiedUsageMonitor --probe` runs one real fetch per detected provider and
/// prints what came back, then exits.
///
/// It exercises exactly the code the menu bar runs, so when a provider's
/// undocumented API shifts this says which one broke and how, without waiting
/// on a poll cycle or squinting at a gauge.
enum Probe {
    /// Collects output off the main thread; `lines` is mutated from several
    /// concurrent tasks.
    private final class Collector {
        private let lock = NSLock()
        private var lines: [String: String] = [:]

        func set(_ id: String, _ text: String) {
            lock.lock()
            lines[id] = text
            lock.unlock()
        }

        func ordered(_ ids: [String]) -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return ids.compactMap { lines[$0] }
        }
    }

    static func run() {
        let providers: [UsageProvider] = [
            CodexProvider(), AnthropicProvider(), AntigravityProvider(),
        ]
        let collector = Collector()
        let group = DispatchGroup()

        for provider in providers {
            let header = "\(provider.displayName) [\(provider.id)]"
            guard provider.isInstalled() else {
                collector.set(provider.id, "\(header)\n  " + L10n.t("probe.notInstalled", "not installed"))
                continue
            }

            group.enter()
            Task {
                defer { group.leave() }
                var output = [header]
                do {
                    let snapshot = try await provider.fetch()
                    if let plan = snapshot.planLabel {
                        output.append("  " + L10n.f("probe.plan", "plan: %@", plan))
                    }
                    for window in snapshot.windows {
                        let prefix = window.isPrimary ? "▸" : "·"
                        let groupName = window.group.map { "\($0) / " } ?? ""
                        let reset = Format.countdown(to: window.resetsAt)
                            .map { L10n.f("probe.resetsIn", " (resets in %@)", $0) } ?? ""
                        let remaining = L10n.f("probe.remaining", "%.1f%% left", window.remainingPercent)
                        output.append("  \(prefix) \(groupName)\(window.label): \(remaining)\(reset)")
                    }
                    for note in snapshot.notes { output.append("  \(note)") }
                } catch {
                    output.append("  " + L10n.f("probe.failed", "failed: %@", error.localizedDescription))
                }
                collector.set(provider.id, output.joined(separator: "\n"))
            }
        }

        group.wait()
        print(collector.ordered(providers.map(\.id)).joined(separator: "\n\n"))
    }
}
