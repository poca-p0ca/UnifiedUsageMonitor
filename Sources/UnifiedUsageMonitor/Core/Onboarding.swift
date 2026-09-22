import Foundation

/// Whether the first-run explanation has been shown.
///
/// It exists because of what the first poll does: reading Claude's and
/// Antigravity's credentials means reading a keychain item another app owns,
/// and macOS answers that with an "allow access" dialog. The providers refresh
/// concurrently, so without this the user meets two unexplained system dialogs
/// a few seconds after launching a menu bar app that has shown them nothing
/// yet — and the wrong button on those dialogs ("Allow" rather than "Always
/// Allow") quietly signs them up to answer again forever.
enum Onboarding {
    private static let key = "OnboardingCompletedVersion"

    /// Bumping this shows the explanation again after a change worth
    /// re-reading. It is not the app version: most releases should not
    /// interrupt anyone.
    private static let current = 1

    static var isComplete: Bool {
        UserDefaults.standard.integer(forKey: key) >= current
    }

    static func markComplete() {
        UserDefaults.standard.set(current, forKey: key)
    }

    /// `--reset-onboarding` puts the app back to its first-run state, so the
    /// window can be checked without clearing the whole preferences domain.
    static func resetIfRequested() {
        guard CommandLine.arguments.contains("--reset-onboarding") else { return }
        UserDefaults.standard.removeObject(forKey: key)
        DebugLog.note("onboarding reset")
    }
}
