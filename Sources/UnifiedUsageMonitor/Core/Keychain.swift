import Foundation
import Security

/// Minimal generic-password access: the credential blobs the CLIs already keep
/// in the login keychain, plus this app's own items.
///
/// Reading another app's item raises the "allow access" prompt unless this app
/// is on that item's ACL, and only the item's owner controls that ACL. So reads
/// of foreign items are kept as rare as possible, and anything this app can own
/// outright goes in its own item via `upsert`, which never prompts.
enum Keychain {
    /// The service this app owns its items under. Kept as a literal rather than
    /// read from `Bundle.main`: `--probe` runs the bare binary in `build/`,
    /// which has no bundle and would report no identifier at all. Matches
    /// `CFBundleIdentifier` in `Resources/Info.plist`; change both together.
    static let ownService = "poca.p0ca.UnifiedUsageMonitor"

    static func readString(service: String, account: String? = nil) throws -> String {
        if service == ownService {
            return try readStringNative(service: service, account: account)
        } else {
            return try readStringCLI(service: service, account: account)
        }
    }

    private static func readStringCLI(service: String, account: String? = nil) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        var args = ["find-generic-password", "-s", service, "-w"]
        if let account = account {
            args.append("-a")
            args.append(account)
        }
        task.arguments = args

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            throw KeychainError(status: errSecDecode, service: service)
        }

        if task.terminationStatus == 44 {
            throw KeychainError(status: errSecItemNotFound, service: service)
        }
        guard task.terminationStatus == 0 else {
            throw KeychainError(status: OSStatus(task.terminationStatus), service: service)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: errSecDecode, service: service)
        }
        return text.trimmingCharacters(in: .newlines)
    }

    private static func readStringNative(service: String, account: String? = nil) throws -> String {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            throw KeychainError(status: status, service: service)
        }
        guard let data = item as? Data, let text = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: errSecDecode, service: service)
        }
        return text
    }

    /// Attribute-only lookup: it does not decrypt the item, so unlike
    /// `readString` it never raises the "allow access" prompt.
    static func exists(service: String, account: String? = nil) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    /// Writes one of this app's own items, creating it if needed. Because the
    /// app creates the item, it owns the ACL and no prompt ever appears.
    static func upsert(_ value: String, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(value.utf8)

        let status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw KeychainError(status: status, service: service)
        }

        var insert = query
        insert[kSecValueData as String] = data
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else {
            throw KeychainError(status: added, service: service)
        }
    }

    /// Rewrites another app's item in place, through `/usr/bin/security`.
    ///
    /// Not `SecItemUpdate`: a native write from this app re-stamps the item's
    /// partition list with this app's own code hash and drops the
    /// `apple-tool:` entry the CLI owner relies on. Every later
    /// `security find-generic-password` then raises the "allow access" dialog
    /// — for this app and for the CLI itself — until someone types the
    /// keychain password. Writing the way the owner does (`security
    /// add-generic-password -U`) leaves the ACL as it was.
    ///
    /// The command goes in on stdin via `security -i`, so the secret does not
    /// appear in a process listing. That reader truncates lines at about 4KB;
    /// a value too long for it falls back to an argument, which only this
    /// user's processes can see.
    static func writeString(_ value: String, service: String) throws {
        // `-U` only updates when account and service both match; without the
        // right account it would add a second item instead.
        guard let account = account(service: service) else {
            throw KeychainError(status: errSecItemNotFound, service: service)
        }
        let target = "-U -a \(quoted(account)) -s \(quoted(service))"
        let line = "add-generic-password \(target) -w \(quoted(value))\n"

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        let input = Pipe()
        let viaStdin = line.utf8.count < 4000 && !value.contains(where: \.isNewline)
        if viaStdin {
            task.arguments = ["-i"]
            task.standardInput = input
        } else {
            let hex = Data(value.utf8).map { String(format: "%02x", $0) }.joined()
            task.arguments = ["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex]
        }
        task.standardOutput = Pipe()
        let errors = Pipe()
        task.standardError = errors

        do {
            try task.run()
            if viaStdin {
                input.fileHandleForWriting.write(Data(line.utf8))
                try input.fileHandleForWriting.close()
            }
            task.waitUntilExit()
        } catch {
            throw KeychainError(status: errSecIO, service: service)
        }

        // `security -i` exits 0 even when a command inside it fails, so the
        // error stream is the only reliable signal.
        let complaint = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard task.terminationStatus == 0,
              complaint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            DebugLog.note("keychain write via security failed: \(complaint.prefix(160))")
            throw KeychainError(status: errSecIO, service: service)
        }
    }

    /// The account an item is stored under, read from its attributes only —
    /// no decryption, so no prompt.
    private static func account(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let attributes = item as? [String: Any] else { return nil }
        return attributes[kSecAttrAccount as String] as? String
    }

    /// Quotes an argument for `security -i`, which splits its input line on
    /// whitespace and honours double quotes.
    private static func quoted(_ argument: String) -> String {
        "\"" + argument.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    struct KeychainError: LocalizedError {
        let status: OSStatus
        let service: String

        var isMissing: Bool { status == errSecItemNotFound }

        var errorDescription: String? {
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return L10n.f("error.keychain", "Keychain '%1$@' access failed — %2$@", service, detail)
        }
    }
}
