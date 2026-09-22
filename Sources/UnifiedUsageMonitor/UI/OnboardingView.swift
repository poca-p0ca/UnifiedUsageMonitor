import SwiftUI

/// The first-run explanation.
///
/// Its whole job is the few seconds after the first launch, when reading
/// Claude's and Antigravity's credentials makes macOS put up an "allow access"
/// dialog for each — two system dialogs, at once, from a menu bar app that has
/// shown the user nothing yet. The window says what is about to happen and why
/// "Always Allow" is the answer; the first fetch waits until it is dismissed.
struct OnboardingView: View {
    /// Detected services, and whether reading each one raises the prompt. The
    /// flag decides whether the keychain section is worth showing at all.
    let tools: [(name: String, promptsForKeychain: Bool)]
    let onStart: () -> Void

    @Environment(\.isSnapshotRender) private var isSnapshotRender

    private static let repository = "https://github.com/poca-p0ca/UnifiedUsageMonitor"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            body(for: tools)
            Divider()
            footer
        }
        .frame(width: 420)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t("onboarding.title", "Unified Usage Monitor"))
                    .font(.system(size: 15, weight: .semibold))
                Text(L10n.t("onboarding.subtitle",
                            "See what is left of every AI service you use, in one place."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private func body(for tools: [(name: String, promptsForKeychain: Bool)]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if tools.isEmpty {
                section(L10n.t("onboarding.none.title", "No services found yet"),
                        L10n.t("onboarding.none.body",
                               "Install and sign in to Claude Code, Codex or Antigravity and its gauge appears on its own — no need to reopen this app."))
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    Text(L10n.t("onboarding.detected", "Services found on this Mac"))
                        .font(.system(size: 12, weight: .semibold))
                    ForEach(tools, id: \.name) { tool in
                        HStack(spacing: 7) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(tool.name)
                                .font(.system(size: 11))
                            Spacer(minLength: 0)
                        }
                    }
                }

                if tools.contains(where: \.promptsForKeychain) {
                    section(L10n.t("onboarding.keychain.title", "Please choose “Always Allow”"),
                            L10n.t("onboarding.keychain.body",
                                   "macOS asks for permission once per service the first time, so usage can be read. Plain “Allow” asks again on every refresh — choose “Always Allow”."))
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t("onboarding.privacy.title", "Your logins are not taken anywhere"))
                    .font(.system(size: 12, weight: .semibold))
                Text(L10n.t("onboarding.privacy.body",
                            "Each service's login is used only to read its usage. Nothing is sent to any other server and you are never asked for a password. A lapsed session is refreshed the same way that service's own CLI refreshes it."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(L10n.t("onboarding.source", "All source is public on GitHub."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                link
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private var link: some View {
        // `Link` gives the pointer and the open behaviour for free, and unlike
        // `pointerStyle` it is available on the macOS 14 this app targets.
        if let url = URL(string: Self.repository), !isSnapshotRender {
            Link(Self.repository, destination: url)
                .font(.system(size: 11))
        } else {
            Text(Self.repository)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Text(L10n.t("onboarding.menubarHint", "The gauges live in the menu bar."))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            if isSnapshotRender {
                Text(L10n.t("onboarding.start", "Start"))
                    .font(.system(size: 12, weight: .medium))
            } else {
                Button(L10n.t("onboarding.start", "Start"), action: onStart)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}
