import Foundation

/// Filesystem probes shared by the providers' `isInstalled()` checks, plus the
/// executable lookup the Claude version and the Antigravity client scan need.
enum Installed {
    static func exists(_ homeRelativePath: String) -> Bool {
        FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(homeRelativePath).path
        )
    }

    static func anyExists(_ homeRelativePaths: [String]) -> Bool {
        homeRelativePaths.contains(where: exists)
    }

    // MARK: - Finding an executable

    /// Directories a CLI is plausibly installed into. Deliberately not `$PATH`.
    ///
    /// An app launched from Finder or Login Items inherits launchd's
    /// environment, and `launchctl getenv PATH` is empty on a stock Mac — the
    /// shell's PATH is built by `.zshrc`, which never runs for a GUI process.
    /// Reading `$PATH` here would find `/usr/bin:/bin` and nothing a CLI is
    /// ever installed into, so the known locations are searched directly and
    /// the login shell is asked only as a fallback.
    private static var searchDirectories: [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var directories = [
            // Native installers and the usual user-level bin dirs.
            "\(home.path)/.local/bin",
            "\(home.path)/bin",
            // Homebrew, Apple Silicon then Intel.
            "/opt/homebrew/bin",
            "/usr/local/bin",
            // Node version and package managers, which is where an npm -g
            // install of claude or codex lands.
            "\(home.path)/.npm-global/bin",
            "\(home.path)/.npm-packages/bin",
            "\(home.path)/.yarn/bin",
            "\(home.path)/.bun/bin",
            "\(home.path)/.volta/bin",
            "\(home.path)/.deno/bin",
            // Antigravity's IDE-installed shims.
            "\(home.path)/.antigravity/antigravity/bin",
            "\(home.path)/.antigravity/bin",
            "\(home.path)/.gemini/antigravity-cli/bin",
            "/Applications/Antigravity.app/Contents/Resources/app/bin",
        ].map(URL.init(fileURLWithPath:))

        // nvm keeps one bin directory per installed Node version, so the path
        // cannot be written down — it has to be enumerated.
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm.path) {
            directories += versions
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .map { nvm.appendingPathComponent("\($0)/bin") }
        }
        return directories
    }

    private static let lookupLock = NSLock()
    private static var lookupCache: [String: URL?] = [:]

    /// Resolves `name` to a real executable, or nil.
    ///
    /// Must not be called from the main actor: the fallback runs the user's
    /// login shell, which executes their whole profile and can take seconds.
    /// The providers call this only from `fetch()`, which runs off the main
    /// actor; `isInstalled()` runs on every scheduler tick and must not.
    static func locateExecutable(_ name: String) -> URL? {
        lookupLock.lock()
        defer { lookupLock.unlock() }
        if let cached = lookupCache[name] { return cached }

        let found = searchKnownDirectories(for: name) ?? askLoginShell(for: name)
        lookupCache[name] = found
        if let found {
            DebugLog.note("located \(name) at \(found.path)")
        } else {
            DebugLog.note("could not locate \(name) in the known directories or via the login shell")
        }
        return found
    }

    private static func searchKnownDirectories(for name: String) -> URL? {
        let fileManager = FileManager.default
        for directory in searchDirectories {
            let candidate = directory.appendingPathComponent(name)
            // A dangling symlink is common here — Antigravity's IDE shim points
            // into an app bundle that may no longer be installed — and
            // `isExecutableFile` follows the link, so it rejects those.
            guard fileManager.isExecutableFile(atPath: candidate.path) else { continue }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else { continue }
            return candidate
        }
        return nil
    }

    /// Last resort for an install in a directory nobody could have guessed.
    ///
    /// `$SHELL -l -c 'command -v <name>'` is the only way to see the PATH the
    /// user actually has, since that PATH exists only inside their shell
    /// profile. Run at most once per name per launch, and bounded: a profile
    /// that hangs must not hang a refresh.
    private static func askLoginShell(for name: String) -> URL? {
        // Reject anything that is not a plain command name before it reaches a
        // shell, so this can never become a way to run something else.
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { return nil }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: shell)
        task.arguments = ["-l", "-c", "command -v \(name)"]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = Pipe()

        do { try task.run() } catch { return nil }

        // Read before waiting: a full pipe buffer would deadlock the child.
        let data = output.fileHandleForReading.readDataToEndOfFile()

        let deadline = Date().addingTimeInterval(5)
        while task.isRunning, Date() < deadline { usleep(50_000) }
        if task.isRunning {
            task.terminate()
            DebugLog.note("login shell lookup for \(name) timed out")
            return nil
        }

        guard task.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: text)
        else { return nil }
        return URL(fileURLWithPath: text)
    }

    // MARK: - Claude Code version

    /// Resolves the Claude Code CLI version, so the User-Agent tracks whatever
    /// is installed instead of a number baked in at build time — the most
    /// perishable constant in this app, and the one that decides which
    /// rate-limit bucket the request lands in.
    ///
    /// Four layouts, because the install method varies: the native installer's
    /// versioned directory, a Homebrew cellar path, an npm package directory,
    /// and whatever the CLI reports about itself.
    static func claudeCodeVersion() -> String? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let fileManager = FileManager.default

        // Native installer: ~/.local/bin/claude is a symlink whose target is
        // named after the version.
        let launcher = home.appendingPathComponent(".local/bin/claude").path
        if let target = try? fileManager.destinationOfSymbolicLink(atPath: launcher) {
            let name = (target as NSString).lastPathComponent
            if isVersionLike(name) { return name }
        }

        // Native installer, launcher missing: newest versioned directory wins.
        let versions = home.appendingPathComponent(".local/share/claude/versions")
        if let entries = try? fileManager.contentsOfDirectory(atPath: versions.path),
           let newest = entries.filter(isVersionLike).max(by: {
               $0.compare($1, options: .numeric) == .orderedAscending
           }) {
            return newest
        }

        // Homebrew or npm: find the executable wherever it went, then read the
        // version out of the path it resolves into.
        guard let executable = locateExecutable("claude") else { return nil }
        let resolved = executable.resolvingSymlinksInPath()

        // Homebrew: .../Cellar/claude-code/<version>/bin/claude
        if let versionComponent = resolved.pathComponents.reversed().first(where: isVersionLike) {
            return versionComponent
        }

        // npm: .../node_modules/@anthropic-ai/claude-code/cli.js, whose package
        // directory carries the version in package.json.
        var directory = resolved.deletingLastPathComponent()
        for _ in 0..<3 {
            let manifest = directory.appendingPathComponent("package.json")
            if let data = try? Data(contentsOf: manifest),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let version = json["version"] as? String,
               isVersionLike(version) {
                return version
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    private static func isVersionLike(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isNumber || $0 == "." } && name.contains(".")
    }
}
