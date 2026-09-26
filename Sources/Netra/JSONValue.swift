import Foundation

/// Lenient readers for untyped JSON from undocumented provider APIs, which
/// send the same field as a number in one response and a string in another.
enum JSONValue {
    static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string)
        default: return nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: return number.intValue
        case let string as String: return Int(string)
        default: return nil
        }
    }

    /// Trimmed, non-empty string; the literal "null" some APIs send counts as absent.
    static func string(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "null" ? nil : trimmed
    }
}

/// ISO-8601 timestamps with or without fractional seconds (Anthropic sends
/// microseconds, Codex milliseconds, ccusage either).
enum ISODate {
    // ISO8601DateFormatter is documented as thread-safe.
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let whole = ISO8601DateFormatter()

    static func parse(_ string: String) -> Date? {
        fractional.date(from: string) ?? whole.date(from: string)
    }
}

/// ccusage's period keys ("2026-09-26", "2026-09", Monday week starts) are
/// Gregorian, ASCII-digit strings in the local time zone. Every formatter
/// that reads or writes them must pin that, or a Mac set to e.g. the
/// Japanese calendar or Arabic digits silently drops every row.
enum PeriodKeys {
    /// Gregorian calendar in the given calendar's time zone.
    static func gregorian(_ base: Calendar = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = base.timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    /// Monday-first ISO weeks, as ccusage buckets them regardless of locale.
    static func weeks(_ base: Calendar = .current) -> Calendar {
        var calendar = gregorian(base)
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    static func formatter(_ format: String, _ base: Calendar = .current) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = gregorian(base)
        formatter.timeZone = base.timeZone
        formatter.dateFormat = format
        return formatter
    }

    static func day(_ date: Date, _ base: Calendar = .current) -> String {
        formatter("yyyy-MM-dd", base).string(from: date)
    }

    static func month(_ date: Date, _ base: Calendar = .current) -> String {
        formatter("yyyy-MM", base).string(from: date)
    }

    /// The Monday that starts `date`'s week, as a day key and a date.
    static func weekStart(_ date: Date, _ base: Calendar = .current) -> (key: String, date: Date) {
        let calendar = weeks(base)
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        return (day(start, base), start)
    }
}
