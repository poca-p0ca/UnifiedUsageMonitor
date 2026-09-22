import AppKit

// Diagnostic path: fetch once from every detected provider and print. Checked
// before AppKit is touched, so it works over SSH and on a CI runner with no
// window server — it needs nothing AppKit provides.
if CommandLine.arguments.contains("--probe") {
    Probe.run()
    exit(0)
}

let app = NSApplication.shared
// Menu bar only: no Dock icon, no main window.
app.setActivationPolicy(.accessory)

// Debug-only path: render the popover to PNGs and exit without showing any UI.
if let index = CommandLine.arguments.firstIndex(of: "--snapshot"),
   index + 1 < CommandLine.arguments.count {
    let directory = CommandLine.arguments[index + 1]
    MainActor.assumeIsolated { Snapshot.run(directory: directory) }
    exit(0)
}

let delegate = AppDelegate()
app.delegate = delegate
app.run()
