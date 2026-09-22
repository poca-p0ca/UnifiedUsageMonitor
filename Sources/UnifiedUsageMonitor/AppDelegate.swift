import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: UsageStore!
    private var statusController: StatusItemController!
    private var onboarding: OnboardingWindowController?

    /// main.swift's top-level code is not main-actor isolated, so the
    /// initializer must not be either. It touches no isolated state.
    nonisolated override init() { super.init() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Order drives both the menu bar text and the gauge row, left to right.
        store = UsageStore(providers: [CodexProvider(), AnthropicProvider(), AntigravityProvider()])
        statusController = StatusItemController(store: store)
        DebugLog.note("launched")

        Onboarding.resetIfRequested()
        guard !Onboarding.isComplete else {
            store.start()
            return
        }

        // Detection only queries keychain attributes, never values, so the
        // window can name the tools without triggering the very dialogs it is
        // there to explain. Polling waits until the user has read it.
        let controller = OnboardingWindowController()
        onboarding = controller
        controller.show(tools: store.detectedTools()) { [weak self] in
            self?.onboarding = nil
            self?.store.start()
            DebugLog.note("onboarding finished")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.stop()
    }
}
