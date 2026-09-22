import SwiftUI
import AppKit

enum Format {
    /// Compact remaining-time string: "4h 12m", "38m", "<1m".
    ///
    /// Returns a bare duration, not a sentence — callers wrap it in
    /// `popover.resetsIn` / `menubar.tooltip.reset`, whose word order differs
    /// between languages.
    static func countdown(to date: Date?) -> String? {
        guard let date else { return nil }
        let remaining = date.timeIntervalSinceNow
        guard remaining > 0 else { return L10n.t("duration.imminent", "<1m") }

        let totalMinutes = Int(remaining / 60)
        let days = totalMinutes / (60 * 24)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60

        if days > 0 {
            return hours > 0
                ? L10n.f("duration.dayHour", "%1$dd %2$dh", days, hours)
                : L10n.f("duration.day", "%dd", days)
        }
        if hours > 0 {
            return minutes > 0
                ? L10n.f("duration.hourMinute", "%1$dh %2$dm", hours, minutes)
                : L10n.f("duration.hour", "%dh", hours)
        }
        return L10n.f("duration.minute", "%dm", max(1, minutes))
    }

    /// Reads with the UI language rather than the system one, so a Korean UI on
    /// an English Mac does not mix a 12-hour clock into Korean captions.
    static func clock(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.setLocalizedDateFormatFromTemplate(
            Calendar.current.isDateInToday(date) ? "jm" : "Mdjm"
        )
        return formatter.string(from: date)
    }

    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }
}
