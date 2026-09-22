import AppKit
import SwiftUI

/// Offscreen renderer used to eyeball the popover without opening it:
/// `UnifiedUsageMonitor --snapshot <dir>` writes light and dark PNGs and exits.
/// Nothing here runs in normal operation.
@MainActor
enum Snapshot {
    /// A provider stand-in so preview state needs no network access.
    private final class StubProvider: UsageProvider {
        let id: String
        let displayName: String
        let shortTag: String
        let minimumInterval: TimeInterval = .infinity
        init(id: String, displayName: String, shortTag: String) {
            self.id = id
            self.displayName = displayName
            self.shortTag = shortTag
        }
        func isInstalled() -> Bool { true }
        func fetch() async throws -> ProviderSnapshot { throw ProviderError.notConfigured("stub") }
    }

    static func run(directory: String) {
        let codex = StubProvider(id: "codex", displayName: "ChatGPT · Codex", shortTag: "GPT")
        let claude = StubProvider(id: "anthropic", displayName: "Claude", shortTag: "CL")

        let codexState = ProviderState.loaded(ProviderSnapshot(
            providerID: "codex",
            displayName: "ChatGPT · Codex",
            shortTag: "GPT",
            planLabel: "prolite",
            windows: [
                UsageWindow(id: "primary", label: L10n.t("window.day7", "7-day window"), usedPercent: 85,
                            resetsAt: Date().addingTimeInterval(598_282),
                            windowSeconds: 604_800, isPrimary: true),
                UsageWindow(id: "spark-5h", label: L10n.t("window.hour5", "5-hour window"), usedPercent: 0,
                            resetsAt: Date().addingTimeInterval(18_000),
                            windowSeconds: 18_000, isPrimary: false,
                            group: "GPT-5.3-Codex-Spark"),
                UsageWindow(id: "spark-7d", label: L10n.t("window.day7", "7-day window"), usedPercent: 4,
                            resetsAt: Date().addingTimeInterval(599_602),
                            windowSeconds: 604_800, isPrimary: false,
                            group: "GPT-5.3-Codex-Spark"),
            ],
            fetchedAt: Date(),
            notes: [L10n.f("note.credits.balance", "Credit balance: %@", "0")]
        ))

        let claudeState = ProviderState.loaded(ProviderSnapshot(
            providerID: "anthropic",
            displayName: "Claude",
            shortTag: "CL",
            planLabel: "max_5x",
            windows: [
                UsageWindow(id: "five_hour", label: L10n.t("window.claude.session", "5h session"), usedPercent: 78,
                            resetsAt: Date().addingTimeInterval(9_400),
                            windowSeconds: 18_000, isPrimary: true),
                UsageWindow(id: "weekly_all", label: L10n.t("window.claude.weeklyAll", "7d · all models"), usedPercent: 41,
                            resetsAt: Date().addingTimeInterval(300_000),
                            windowSeconds: 604_800, isPrimary: false),
                UsageWindow(id: "weekly_fable", label: L10n.f("window.claude.weeklyScoped", "7d · %@", "Fable"), usedPercent: 92,
                            resetsAt: Date().addingTimeInterval(300_000),
                            windowSeconds: 604_800, isPrimary: false),
            ],
            fetchedAt: Date(),
            notes: []
        ))

        let antigravity = StubProvider(id: "antigravity", displayName: "Antigravity", shortTag: "AG")
        let antigravityState = ProviderState.loaded(ProviderSnapshot(
            providerID: "antigravity",
            displayName: "Antigravity",
            shortTag: "AG",
            planLabel: "free-tier",
            windows: [
                UsageWindow(id: "gemini-weekly", label: "Gemini", usedPercent: 33.5,
                            resetsAt: Date().addingTimeInterval(603_000),
                            windowSeconds: 604_800, isPrimary: true),
                UsageWindow(id: "3p-weekly",
                            label: L10n.t("window.antigravity.thirdParty", "Other models"),
                            usedPercent: 0,
                            resetsAt: Date().addingTimeInterval(603_400),
                            windowSeconds: 604_800, isPrimary: false),
            ],
            fetchedAt: Date(),
            notes: []
        ))

        let store = UsageStore(previewProviders: [codex, claude, antigravity],
                               states: ["codex": codexState,
                                        "anthropic": claudeState,
                                        "antigravity": antigravityState])

        // The background is stated literally: NSColor semantic colours resolve
        // against the process appearance, which an offscreen render does not
        // switch, so `.windowBackgroundColor` would stay light in both passes.
        // Other machines may have only one tool, or none, so those layouts are
        // rendered too rather than assumed.
        // The single-tool render doubles as the stale case: a failed fetch
        // that keeps its last reading.
        let staleClaude = claudeState.snapshot.map {
            ProviderState.stale($0, message: L10n.t("error.claude.expired",
                                                    "Token expired — run `claude` in a terminal"))
        } ?? claudeState
        let single = UsageStore(previewProviders: [claude], states: ["anthropic": staleClaude])
        let none = UsageStore(previewProviders: [], states: [:])

        render(store: store, name: "light", isDark: false, directory: directory)
        render(store: store, name: "dark", isDark: true, directory: directory)
        render(store: single, name: "one", isDark: false, directory: directory)
        render(store: none, name: "none", isDark: false, directory: directory)

        // The first-run window, with the mix of tools most people will see.
        for (name, isDark) in [("onboarding-light", false), ("onboarding-dark", true)] {
            let view = OnboardingView(
                tools: [("ChatGPT · Codex", false),
                        ("Claude", true),
                        ("Antigravity", true)],
                onStart: {}
            )
            .environment(\.isSnapshotRender, true)
            .environment(\.colorScheme, isDark ? .dark : .light)
            .background(isDark ? Color(white: 0.13) : Color(white: 0.97))
            writePNG(view, name: name, directory: directory)
        }
    }

    private static func render(store: UsageStore, name: String, isDark: Bool, directory: String) {
        // No explicit width: PopoverView sizes itself from the provider count,
        // which is exactly what these renders are checking.
        let view = PopoverView(store: store)
            .environment(\.isSnapshotRender, true)
            .environment(\.colorScheme, isDark ? .dark : .light)
            .background(isDark ? Color(white: 0.13) : Color(white: 0.97))
        writePNG(view, name: "popover-\(name)", directory: directory)
    }

    private static func writePNG(_ view: some View, name: String, directory: String) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write(Data("snapshot \(name) failed to render\n".utf8))
            return
        }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try? png.write(to: url)
        print("wrote \(url.path)")
    }
}
