import AppKit
import SwiftUI

/// Shows the first-run window and reports when the user has finished with it.
///
/// A `.accessory` app never becomes active on its own, so the window has to ask
/// for activation or it opens behind whatever the user was looking at — which
/// would defeat the point, since the keychain dialogs it explains are about to
/// appear in front of everything.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var onFinish: (() -> Void)?

    /// - Parameter tools: detected providers, in display order.
    func show(tools: [(name: String, promptsForKeychain: Bool)],
              onFinish: @escaping () -> Void) {
        self.onFinish = onFinish

        let controller = NSHostingController(
            rootView: OnboardingView(tools: tools) { [weak self] in self?.finish() }
        )
        let window = NSWindow(contentViewController: controller)
        window.title = L10n.t("onboarding.window", "Welcome")
        window.styleMask = [.titled, .closable]
        window.setContentSize(controller.view.fittingSize)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Closing the window counts as finishing. Leaving polling switched off
    /// because someone used the close button instead of the button in the
    /// window would look exactly like the app being broken.
    func windowWillClose(_ notification: Notification) {
        finish()
    }

    private func finish() {
        guard let onFinish else { return }
        self.onFinish = nil
        Onboarding.markComplete()
        // Closing from inside `windowWillClose` re-enters the delegate, so the
        // window is let go first and the callback runs after this turn of the
        // run loop.
        let window = self.window
        self.window = nil
        DispatchQueue.main.async {
            window?.close()
            onFinish()
        }
    }
}
