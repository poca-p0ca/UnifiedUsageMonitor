import AppKit
import SwiftUI
import Combine

/// Owns the NSStatusItem, its rendered title, and the popover it toggles.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let store: UsageStore
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    /// Redraws the countdown text between network refreshes.
    private var tickTimer: Timer?

    init(store: UsageStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        // PopoverView sizes itself from the detected provider count; the
        // hosting controller follows its fitting size.
        popover.contentViewController = NSHostingController(rootView: PopoverView(store: store))

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        store.$states
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &cancellables)

        store.$providers
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &cancellables)

        // Swapping the language swaps every string the popover has already
        // laid out, so its hosting controller is rebuilt rather than nudged.
        NotificationCenter.default.addObserver(
            forName: .languageDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildForLanguageChange() }
        }

        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.render() }
        }
        timer.tolerance = 10
        tickTimer = timer

        render()
    }

    // MARK: - Title

    private func render() {
        guard let button = statusItem.button else { return }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let title = NSMutableAttributedString()
        var anyData = false

        if store.providers.isEmpty {
            button.attributedTitle = NSAttributedString(
                string: L10n.t("menubar.noTools", "Usage —"),
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ]
            )
            button.toolTip = L10n.t("menubar.noTools.tooltip",
                                    "None of Claude Code · Codex · Antigravity detected")
            return
        }

        for (provider, state) in store.summaries {
            if title.length > 0 {
                title.append(NSAttributedString(string: "  ", attributes: [.font: font]))
            }

            switch state {
            case .loaded(let snapshot), .stale(let snapshot, _):
                anyData = true
                // A stale reading keeps its number but loses its colour, so a
                // glance at the menu bar never passes old data off as live.
                let isStale: Bool
                if case .stale = state { isStale = true } else { isStale = false }
                let window = snapshot.primaryWindow
                let percent = window.map { Format.percent($0.remainingPercent) } ?? "—"
                let color = isStale
                    ? NSColor.tertiaryLabelColor
                    : GaugeAccent.nsColor(providerID: provider.id, window: window)
                title.append(NSAttributedString(string: "● ", attributes: [
                    .font: NSFont.systemFont(ofSize: 8),
                    .foregroundColor: color,
                    .baselineOffset: 1,
                ]))
                title.append(NSAttributedString(string: "\(provider.shortTag) \(percent)", attributes: [
                    .font: font,
                    .foregroundColor: isStale ? NSColor.secondaryLabelColor : NSColor.labelColor,
                ]))
            case .loading, .idle:
                title.append(NSAttributedString(string: "\(provider.shortTag) …", attributes: [
                    .font: font,
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            case .unavailable, .failed:
                title.append(NSAttributedString(string: "\(provider.shortTag) —", attributes: [
                    .font: font,
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ]))
            }
        }

        button.attributedTitle = title
        if popover.isShown { sizeToFitContent() }
        button.toolTip = anyData ? tooltip() : L10n.t("menubar.noData.tooltip", "No usage fetched yet")
    }

    private func tooltip() -> String {
        store.summaries.compactMap { provider, state -> String? in
            guard let snapshot = state.snapshot else { return nil }
            let lines = snapshot.windows.map { window -> String in
                let reset = Format.countdown(to: window.resetsAt)
                    .map { L10n.f("menubar.tooltip.reset", " · resets in %@", $0) } ?? ""
                return L10n.f("menubar.tooltip.row", "  %1$@: %2$@ left%3$@",
                              window.label, Format.percent(window.remainingPercent), reset)
            }
            return ([provider.displayName] + lines).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    // MARK: - Interaction

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp
        if isRightClick {
            showContextMenu(from: sender)
        } else {
            togglePopover(from: sender)
        }
    }

    private func togglePopover(from sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }

        store.refresh(force: false)
        sizeToFitContent()
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Pins the popover to its content's real size before it is positioned.
    ///
    /// A SwiftUI hosting controller reports its size only once it has laid out.
    /// Shown first and measured after, the popover is placed against a size it
    /// no longer has, and the window ends up anchored wrongly — far enough up,
    /// with this content, to sit over the menu bar.
    private func sizeToFitContent() {
        guard let content = popover.contentViewController else { return }
        content.view.layoutSubtreeIfNeeded()
        let size = content.view.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        popover.contentSize = size
    }

    private func showContextMenu(from sender: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: L10n.t("menu.refreshNow", "Refresh Now"),
                     action: #selector(refreshNow), keyEquivalent: "r").target = self
        menu.addItem(withTitle: L10n.t("menu.openLogs", "Open Debug Logs"),
                     action: #selector(openLogs), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(languageMenuItem())
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.t("menu.quit", "Quit"),
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Attaching the menu makes the next click open it; detach right after
        // so the left-click popover keeps working.
        statusItem.menu = menu
        sender.performClick(nil)
        statusItem.menu = nil
    }

    /// macOS picks the language from the user's preferred list, which is the
    /// right default. This override exists because the two audiences do not
    /// line up: plenty of people run macOS in English and would rather read
    /// this in Korean, or the reverse.
    private func languageMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: L10n.t("menu.language", "Language"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let system = NSMenuItem(title: L10n.t("menu.language.system", "Match System"),
                                action: #selector(selectLanguage(_:)), keyEquivalent: "")
        system.target = self
        system.representedObject = nil
        system.state = L10n.override == nil ? .on : .off
        submenu.addItem(system)
        submenu.addItem(.separator())

        for language in L10n.supported {
            let entry = NSMenuItem(title: language.name,
                                   action: #selector(selectLanguage(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = language.code
            entry.state = L10n.override == language.code ? .on : .off
            submenu.addItem(entry)
        }

        item.submenu = submenu
        return item
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        L10n.override = sender.representedObject as? String
    }

    /// A SwiftUI view tree caches the strings it was built with, so the popover
    /// is replaced wholesale instead of being asked to redraw.
    private func rebuildForLanguageChange() {
        let wasShown = popover.isShown
        if wasShown { popover.performClose(nil) }
        popover.contentViewController = NSHostingController(rootView: PopoverView(store: store))
        render()
        if wasShown, let button = statusItem.button { togglePopover(from: button) }
    }

    @objc private func refreshNow() { store.refresh(force: true) }

    @objc private func openLogs() {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/UnifiedUsageMonitor")
        NSWorkspace.shared.open(url)
    }
}
