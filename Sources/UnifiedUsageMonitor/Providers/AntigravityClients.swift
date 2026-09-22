import Foundation

/// Finds Antigravity's OAuth client credentials in the CLI you already have
/// installed, instead of carrying a copy of them in this repository.
///
/// Refreshing a Google token for this API needs a `client_id` *and* a
/// `client_secret`. Those belong to Google and live in the Antigravity CLI
/// binary. Hardcoding them here would mean publishing someone else's
/// credentials, and it would also rot: a CLI release that adds or rotates a
/// client would break the gauge until this project cut a new build. Reading
/// them out of the installed binary avoids both.
///
/// Nothing is ever logged but client IDs. Secrets stay in memory and, once one
/// is known to work, in this app's own keychain item — never on disk in the
/// clear and never in the debug log.
enum AntigravityClients {
    struct Client: Equatable {
        let id: String
        let secret: String
    }

    /// Executable names the CLI ships under. `agy` is current; `antigravity`
    /// is the older name and the IDE's shim. Where to look for them is
    /// `Installed.locateExecutable`'s problem, not this file's.
    private static let executableNames = ["agy", "antigravity"]

    /// A Google installed-app secret: the marker plus exactly 28 characters.
    /// The fixed length matters — in the binary these sit end to end with no
    /// separator, so a greedy match would swallow the next one.
    private static let secretMarker = Data("GOCSPX-".utf8)
    private static let secretBodyLength = 28
    private static let clientIDSuffix = Data(".apps.googleusercontent.com".utf8)

    /// Scanning 180MB is cheap once and pointless twice. Keyed by the binary's
    /// identity so a CLI update is rescanned and nothing else is.
    private static let lock = NSLock()
    private static var cache: (key: String, clients: [Client])?

    /// The clients found in the installed CLI, or an empty array if there is no
    /// CLI to read. Safe to call from any thread.
    static func discover() -> [Client] {
        lock.lock()
        defer { lock.unlock() }

        guard let binary = locateCLI(),
              let attributes = try? FileManager.default.attributesOfItem(atPath: binary.path),
              let size = attributes[.size] as? Int
        else {
            cache = nil
            return []
        }

        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(binary.path)|\(size)|\(modified)"
        if let cache, cache.key == key { return cache.clients }

        // A binary far larger than any plausible CLI is more likely a mistaken
        // path than something worth spending seconds scanning.
        guard size < 600 * 1024 * 1024 else {
            DebugLog.note("antigravity: \(binary.lastPathComponent) is \(size / 1_048_576)MB, not scanning")
            return []
        }

        let started = Date()
        let clients = scan(binary)
        cache = (key, clients)

        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        if clients.isEmpty {
            DebugLog.note("antigravity: no OAuth clients found in \(binary.path) (\(elapsed)ms)")
        } else {
            let ids = clients.map { String($0.id.prefix(13)) }.joined(separator: ", ")
            DebugLog.note("antigravity: \(clients.count) OAuth client(s) read from the CLI — \(ids) (\(elapsed)ms)")
        }
        return clients
    }

    /// The CLI path discovery settled on, for diagnostics.
    static func cliPath() -> String? { locateCLI()?.path }

    // MARK: - Locating

    private static func locateCLI() -> URL? {
        for name in executableNames {
            guard let executable = Installed.locateExecutable(name) else { continue }
            // Installers leave a symlink to the real binary; the scan needs the
            // file itself, and its size and mtime are the cache key.
            let resolved = executable.resolvingSymlinksInPath()
            guard FileManager.default.isReadableFile(atPath: resolved.path) else { continue }
            // The IDE ships a small launcher script next to the real binary. A
            // few KB cannot hold an OAuth client, so keep looking.
            let size = (try? FileManager.default.attributesOfItem(atPath: resolved.path))?[.size] as? Int
            guard (size ?? 0) > 1_000_000 else { continue }
            return resolved
        }
        return nil
    }

    // MARK: - Scanning

    private static func scan(_ binary: URL) -> [Client] {
        // Mapped, not read: the pages that hold no match are never faulted in.
        guard let data = try? Data(contentsOf: binary, options: [.mappedIfSafe]) else { return [] }

        let secrets = findSecrets(in: data)
        let ids = findClientIDs(in: data)
        guard !secrets.isEmpty, !ids.isEmpty else { return [] }

        // The two are stored in separate string tables, so there is no syntax
        // tying an ID to its secret — only distance. Each ID takes the nearest
        // unclaimed secret. A mispairing is recoverable anyway: the caller
        // falls back to trying the other clients.
        var available = secrets
        var clients: [Client] = []
        for (offset, id) in ids {
            guard let best = available.indices.min(by: {
                abs(available[$0].offset - offset) < abs(available[$1].offset - offset)
            }) else { break }
            clients.append(Client(id: id, secret: available[best].value))
            available.remove(at: best)
        }
        return clients
    }

    private static func findSecrets(in data: Data) -> [(offset: Int, value: String)] {
        var found: [(Int, String)] = []
        var seen = Set<String>()
        forEachOccurrence(of: secretMarker, in: data) { start in
            let bodyStart = start + secretMarker.count
            let bodyEnd = bodyStart + secretBodyLength
            guard bodyEnd <= data.endIndex else { return }
            let body = data[bodyStart..<bodyEnd]
            guard body.allSatisfy(isSecretByte),
                  let text = String(data: body, encoding: .ascii)
            else { return }
            let secret = "GOCSPX-" + text
            if seen.insert(secret).inserted { found.append((start, secret)) }
        }
        return found
    }

    /// Walks back from `.apps.googleusercontent.com` over the exact shape of a
    /// Google client ID: `<digits>-<alphanumeric label>`.
    ///
    /// Matching the shape rather than a character class is the whole trick.
    /// Strings in a stripped binary sit end to end with no terminator, so
    /// consuming "any ID-ish byte" runs straight into the tail of whatever
    /// string precedes this one — which is how a scan first produced
    /// `it1071006060591-…` and then failed to match the issuer claim. The
    /// project number admits digits only, so the walk stops on its own.
    private static func findClientIDs(in data: Data) -> [(offset: Int, value: String)] {
        var found: [(Int, String)] = []
        var seen = Set<String>()
        forEachOccurrence(of: clientIDSuffix, in: data) { suffixStart in
            var cursor = suffixStart
            while cursor > data.startIndex, isLabelByte(data[cursor - 1]) { cursor -= 1 }
            let labelStart = cursor
            guard labelStart < suffixStart else { return }

            guard labelStart > data.startIndex, data[labelStart - 1] == UInt8(ascii: "-") else { return }
            cursor = labelStart - 1

            let dash = cursor
            while cursor > data.startIndex, isDigitByte(data[cursor - 1]) { cursor -= 1 }
            guard cursor < dash else { return }

            let end = suffixStart + clientIDSuffix.count
            guard let id = String(data: data[cursor..<end], encoding: .ascii) else { return }
            if seen.insert(id).inserted { found.append((cursor, id)) }
        }
        return found
    }

    private static func forEachOccurrence(of needle: Data, in data: Data, body: (Int) -> Void) {
        var searchFrom = data.startIndex
        while searchFrom < data.endIndex,
              let hit = data.range(of: needle, options: [], in: searchFrom..<data.endIndex) {
            body(hit.lowerBound)
            searchFrom = hit.lowerBound + 1
        }
    }

    private static func isSecretByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x5F: return true // 0-9 A-Z a-z - _
        default: return false
        }
    }

    private static func isLabelByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true // 0-9 A-Z a-z
        default: return false
        }
    }

    private static func isDigitByte(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }
}
