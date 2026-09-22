import Foundation

/// String lookup for the app's two languages.
///
/// The tables live in `Resources/<lang>.lproj/Localizable.strings` and the
/// build script copies them into the bundle, so adding a language means adding
/// one directory and no Swift.
///
/// Every call passes the English text as `fallback`. That matters beyond
/// tidiness: `--probe` and `--snapshot` are often run against the bare binary
/// in `build/`, which has no bundle to look strings up in, and the fallback is
/// what keeps that output readable instead of printing raw keys.
enum L10n {
    /// The language menu writes here; absent or unknown means "follow macOS".
    static let overrideDefaultsKey = "PreferredLanguage"

    /// Languages offered in the menu, in display order.
    static let supported: [(code: String, name: String)] = [
        ("en", "English"),
        ("ko", "한국어"),
    ]

    private static var table: Bundle = resolvedBundle()

    static func t(_ key: String, _ fallback: String) -> String {
        table.localizedString(forKey: key, value: fallback, table: nil)
    }

    static func f(_ key: String, _ fallback: String, _ arguments: CVarArg...) -> String {
        String(format: t(key, fallback), locale: locale, arguments: arguments)
    }

    /// The locale number and date formatting should follow.
    ///
    /// Not `Locale.current`: that is the system's language, which is not
    /// necessarily the one on screen. An override moves the strings without
    /// moving it, and a system language this app has no table for (Japanese,
    /// say) falls the strings back to English while leaving it Japanese —
    /// either way the clock ends up in a different language from the label
    /// next to it.
    ///
    /// The region stays the user's. Only the language follows the UI, so an
    /// English UI in Korea still formats the way that user expects.
    static var locale: Locale {
        guard let language = override ?? table.preferredLocalizations.first else { return .current }
        var components = Locale.Components(locale: .current)
        components.languageComponents.languageCode = Locale.LanguageCode(language)
        return Locale(components: components)
    }

    // MARK: - Override

    static var override: String? {
        get {
            let code = UserDefaults.standard.string(forKey: overrideDefaultsKey)
            return supported.contains { $0.code == code } ? code : nil
        }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: overrideDefaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: overrideDefaultsKey) }
            table = resolvedBundle()
            NotificationCenter.default.post(name: .languageDidChange, object: nil)
        }
    }

    /// Resolves the override to its `.lproj`, falling back to `Bundle.main`,
    /// which is also what applies when no override is set — macOS then picks
    /// the language from the user's preferred list.
    private static func resolvedBundle() -> Bundle {
        guard let code = override,
              let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else { return .main }
        return bundle
    }
}

extension Notification.Name {
    static let languageDidChange = Notification.Name("poca.p0ca.UnifiedUsageMonitor.languageDidChange")
}
