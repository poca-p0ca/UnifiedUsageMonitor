import Foundation

/// Timestamp parsing shared by the providers. Each API spells its timestamps
/// slightly differently — some with six fractional digits, some with none —
/// and `ISO8601DateFormatter` rejects whichever variant it was not configured
/// for, so try the spellings in turn.
enum Timestamp {
    static func parse(_ value: Any?) -> Date? {
        if let seconds = number(value) {
            // Epoch values arrive in seconds; anything past year ~5138 is millis.
            return Date(timeIntervalSince1970: seconds > 1e11 ? seconds / 1000 : seconds)
        }
        guard let text = value as? String else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }

        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }

        // Strip a fractional-seconds run the formatter would not accept, such
        // as the six digits Google's timestamps carry.
        if let dot = text.firstIndex(of: "."),
           let offset = text[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            return formatter.date(from: text.replacingCharacters(in: dot..<offset, with: ""))
        }
        return nil
    }

    static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }
}
