import SwiftUI

/// True only under `--snapshot`. `ImageRenderer` cannot draw AppKit-backed
/// controls, so a Button comes out as a placeholder glyph; in snapshot mode the
/// two buttons are drawn as their own labels instead. They are inert either
/// way in an offscreen render, and this keeps the rendered PNGs — which are the
/// README screenshots — a faithful picture of the real popover.
private struct SnapshotRenderKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isSnapshotRender: Bool {
        get { self[SnapshotRenderKey.self] }
        set { self[SnapshotRenderKey.self] = newValue }
    }
}

struct PopoverView: View {
    @Environment(\.isSnapshotRender) private var isSnapshotRender
    @ObservedObject var store: UsageStore
    /// Re-renders countdown text between network refreshes.
    @State private var now = Date()

    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    /// Sized from the number of detected tools, so a one-tool machine does not
    /// get a popover with two empty thirds.
    static func width(for providerCount: Int) -> CGFloat {
        providerCount <= 1 ? 300 : min(480, CGFloat(170 * providerCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if store.providers.isEmpty {
                emptyState
            } else {
                columns
            }
            Divider()
            footer
        }
        .frame(width: Self.width(for: store.providers.count))
        .onReceive(ticker) { now = $0 }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "fuelpump")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.tertiary)
            Text(L10n.t("popover.empty.title", "No tools detected"))
                .font(.system(size: 11, weight: .medium))
            Text(L10n.t("popover.empty.body",
                        "Install and sign in to Claude Code,\nCodex or Antigravity to see them here"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(L10n.t("popover.title", "Remaining"))
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.65)
            }
            if isSnapshotRender {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    store.refresh(force: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .help(L10n.t("popover.refresh", "Refresh now"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    /// One column per provider, so a provider's secondary windows sit under its
    /// own gauge instead of in a shared list where they look account-wide.
    private var columns: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(store.summaries.enumerated()), id: \.element.provider.id) { index, entry in
                if index > 0 {
                    Divider()
                }
                ProviderColumn(provider: entry.provider, state: entry.state)
                    .frame(maxWidth: .infinity)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let last = store.lastRefresh, let clock = Format.clock(last) {
                Text(L10n.f("popover.updatedAt", "Updated %@", clock))
            } else {
                Text(L10n.t("popover.neverUpdated", "Not updated yet"))
            }
            Spacer()
            if isSnapshotRender {
                Text(L10n.t("popover.quit", "Quit"))
            } else {
                Button(L10n.t("popover.quit", "Quit")) { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct ProviderColumn: View {
    let provider: UsageProvider
    let state: ProviderState

    var body: some View {
        VStack(spacing: 10) {
            FuelGauge(
                providerID: provider.id,
                title: provider.displayName,
                window: state.snapshot?.primaryWindow,
                caption: caption,
                isStale: isStale
            )

            let extras = secondaryWindows
            if !extras.isEmpty {
                Divider().padding(.horizontal, 12)
                SecondaryWindowList(providerID: provider.id, windows: extras, isStale: isStale)
                    .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 14)
    }

    private var secondaryWindows: [UsageWindow] {
        guard let snapshot = state.snapshot else { return [] }
        let primaryID = snapshot.primaryWindow?.id
        return snapshot.windows.filter { $0.id != primaryID }
    }

    private var isStale: Bool {
        if case .stale = state { return true }
        return false
    }

    private var caption: String? {
        switch state {
        case .loaded(let snapshot):
            guard let window = snapshot.primaryWindow else { return nil }
            return Format.countdown(to: window.resetsAt)
                .map { L10n.f("popover.resetsIn", "resets in %@", $0) }
        case .stale(let snapshot, let message):
            guard let asOf = Format.clock(snapshot.fetchedAt) else { return message }
            return L10n.f("popover.staleCaption", "as of %1$@ · %2$@", asOf, message)
        case .loading, .idle:
            return L10n.t("popover.loading", "Loading…")
        case .unavailable(let reason):
            return reason
        case .failed(let message):
            return message
        }
    }
}

/// Compact list of a provider's non-gauge windows, headed by group name where
/// the provider reports one (a per-model quota, say).
private struct SecondaryWindowList: View {
    let providerID: String
    let windows: [UsageWindow]
    var isStale: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    /// Breathes only while one of these rows is in the critical band.
    private var isBreathing: Bool {
        !isStale && windows.contains { $0.severity == .critical }
    }

    var body: some View {
        if isBreathing {
            TimelineView(.animation) { timeline in
                list(breath: Breath.phase(at: timeline.date))
            }
        } else {
            list(breath: 1)
        }
    }

    private func list(breath: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                if let group = window.group, group != windows[safe: index - 1]?.group {
                    Text(group)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.top, index == 0 ? 0 : 3)
                }
                row(for: window, breath: breath)
            }
        }
    }

    private func row(for window: UsageWindow, breath: Double) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isStale
                      ? GaugeAccent.spent
                      : GaugeAccent.color(providerID: providerID,
                                          window: window,
                                          dark: colorScheme == .dark,
                                          breath: breath))
                .frame(width: 5, height: 5)
            Text(window.label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(Format.percent(window.remainingPercent))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
        }
    }
}

private extension Array {
    /// Lets the group header compare against the previous row without an
    /// index-out-of-range at the top of the list.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
