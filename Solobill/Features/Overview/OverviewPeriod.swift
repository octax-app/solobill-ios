import Foundation

struct PeriodDates: Hashable, Sendable {
    let from: String
    let to: String
}

/// The period choice on the overview, matching `periodDates` in `web/src/client/pages/overview.tsx`.
enum OverviewPeriod: String, CaseIterable, Identifiable {
    case month, quarter, year, custom

    var id: Self { self }

    var title: String {
        switch self {
        case .month: "Month"
        case .quarter: "Quarter"
        case .year: "Year"
        case .custom: "Custom"
        }
    }

    /// The UTC day, because the web and the server both use UTC. A local day would send different
    /// dates from the web for part of each day in any time zone away from UTC.
    static var today: String { Date.now.formatted(.iso8601.year().month().day()) }

    /// `custom` starts from the same dates as `month`.
    func dates(today: String) -> PeriodDates {
        let year = today.prefix(4)
        switch self {
        case .year:
            return PeriodDates(from: "\(year)-01-01", to: today)
        case .quarter:
            let month = Int(today.dropFirst(5).prefix(2)) ?? 1
            let start = (month - 1) / 3 * 3 + 1
            return PeriodDates(from: "\(year)-\(start < 10 ? "0" : "")\(start)-01", to: today)
        case .month, .custom:
            return PeriodDates(from: "\(today.prefix(7))-01", to: today)
        }
    }
}
