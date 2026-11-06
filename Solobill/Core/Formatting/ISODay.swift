import Foundation

/// Calendar days travel as "YYYY-MM-DD" strings, matching the API.
enum ISODay {
    private static func formatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = pattern
        return formatter
    }

    static func string(from date: Date) -> String {
        formatter("yyyy-MM-dd").string(from: date)
    }

    static func date(from day: String) -> Date? {
        formatter("yyyy-MM-dd").date(from: day)
    }

    static var today: String { string(from: .now) }

    /// "1 Nov 2026". Returns the input unchanged if it is not a day.
    static func display(_ day: String?) -> String {
        guard let day else { return "None" }
        guard let date = date(from: day) else { return day }
        return formatter("d MMM yyyy").string(from: date)
    }
}
