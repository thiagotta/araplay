import SwiftUI

/// AraPlay is dark-only on purpose: a player's job is to disappear around the
/// picture, and a light chrome next to a dark video frame fights it. The palette
/// is a neutral near-black with a single warm accent — scarlet, after the macaw.
enum Theme {
    static let canvas = Color(red: 0.055, green: 0.055, blue: 0.063)
    static let sidebar = Color(red: 0.078, green: 0.078, blue: 0.086)
    static let elevated = Color(red: 0.122, green: 0.118, blue: 0.133)
    static let stage = Color.black

    static let accent = Color(red: 1.0, green: 0.29, blue: 0.18)
    static let accentDim = Color(red: 1.0, green: 0.29, blue: 0.18).opacity(0.28)

    static let textPrimary = Color(red: 0.96, green: 0.95, blue: 0.94)
    static let textSecondary = Color(red: 0.62, green: 0.60, blue: 0.62)
    static let textTertiary = Color(red: 0.40, green: 0.39, blue: 0.41)

    static let hairline = Color.white.opacity(0.07)
    static let rowHover = Color.white.opacity(0.05)
    static let rowSelected = Color.white.opacity(0.10)

    /// Corner radius of the floating video card, echoing the window's own.
    static let stageCornerRadius: CGFloat = 12
    static let controlCornerRadius: CGFloat = 10
}

enum Format {
    /// Drops the hours component for anything under an hour, so a three-minute
    /// song reads "2:41" rather than "00:02:41".
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// Remaining time, shown as a negative so it reads as a countdown.
    static func remaining(_ current: Double, _ duration: Double) -> String {
        guard duration > 0 else { return "--:--" }
        return "-" + time(max(duration - current, 0))
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static let timeOfDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    /// "14:32" for today, "Yesterday" for yesterday, "3 wk ago" beyond that —
    /// enough to place a file in time without eating the row's width.
    static func lastPlayed(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return timeOfDayFormatter.string(from: date)
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}
