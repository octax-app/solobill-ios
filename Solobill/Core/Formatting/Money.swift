import Foundation

/// Display and input helpers for amounts, ported from `web/src/shared/money.ts`.
///
/// Amounts and quantities are integers scaled by 10,000, exchange rates by 100,000,000 and
/// percentages by 10,000. Nothing here uses a float. All invoice math stays on the server:
/// these helpers only turn server values into text and typed text into scaled integers.
enum Money {
    static let amountScale = 10_000
    static let fxScale = 100_000_000

    /// Must match `CURRENCIES` on the server. `MoneyTests` compares the two.
    static let currencies: [String: (decimals: Int, name: String)] = [
        "AED": (2, "UAE dirham"),
        "BHD": (3, "Bahraini dinar"),
        "EGP": (2, "Egyptian pound"),
        "EUR": (2, "Euro"),
        "GBP": (2, "Pound sterling"),
        "IQD": (3, "Iraqi dinar"),
        "JOD": (3, "Jordanian dinar"),
        "KWD": (3, "Kuwaiti dinar"),
        "OMR": (3, "Omani rial"),
        "QAR": (2, "Qatari riyal"),
        "SAR": (2, "Saudi riyal"),
        "USD": (2, "US dollar"),
    ]

    static let currencyCodes = currencies.keys.sorted()

    static func decimals(of currency: String) -> Int {
        currencies[currency]?.decimals ?? 2
    }

    /// Rounds half away from zero to the currency's own decimal places, for display.
    private static func rounded(_ amount: Int, currency: String) -> Int {
        var step = 1
        for _ in 0..<(4 - decimals(of: currency)) { step *= 10 }
        let magnitude = (2 * abs(amount) + step) / (2 * step) * step
        return amount < 0 ? -magnitude : magnitude
    }

    /// `a * b / c`, rounded half away from zero, for a positive `c`. The product can pass 64 bits,
    /// as two amounts each carry a scale of 10,000, so it is held at full width.
    private static func scaled(_ a: Int, by b: Int, over c: Int) -> Int {
        let product = a.magnitude.multipliedFullWidth(by: b.magnitude)
        let (quotient, remainder) = c.magnitude.dividingFullWidth(product)
        let magnitude = Int(quotient + (2 * remainder >= c.magnitude ? 1 : 0))
        return (a < 0) != (b < 0) ? -magnitude : magnitude
    }

    /// The tax on a net amount. `percent` is scaled by 10,000. Matches `taxOf` in `money.ts`.
    static func taxOf(_ net: Int, percent: Int, currency: String) -> Int {
        rounded(scaled(net, by: percent, over: 1_000_000), currency: currency)
    }

    /// The share of `part` that belongs to `subtotal` out of `total`. Matches `netShare` in
    /// `money.ts`.
    static func netShare(_ part: Int, subtotal: Int, total: Int, currency: String) -> Int {
        if total == 0 { return 0 }
        return rounded(scaled(part, by: subtotal, over: total), currency: currency)
    }

    private static func plainDecimal(_ value: Int, scaleDigits: Int, minFraction: Int) -> String {
        var digits = String(abs(value))
        if digits.count < scaleDigits + 1 {
            digits = String(repeating: "0", count: scaleDigits + 1 - digits.count) + digits
        }
        let whole = digits.dropLast(scaleDigits)
        var fraction = digits.suffix(scaleDigits)
        while fraction.count > minFraction, fraction.hasSuffix("0") {
            fraction = fraction.dropLast()
        }
        let sign = value < 0 ? "-" : ""
        return fraction.isEmpty ? "\(sign)\(whole)" : "\(sign)\(whole).\(fraction)"
    }

    /// Text for an input field, with no thousands separators or currency code.
    static func amountInput(_ value: Int) -> String { plainDecimal(value, scaleDigits: 4, minFraction: 0) }
    static func fxRateInput(_ value: Int) -> String { plainDecimal(value, scaleDigits: 8, minFraction: 0) }
    static func percentText(_ value: Int) -> String { plainDecimal(value, scaleDigits: 4, minFraction: 0) }

    /// "1,234.500", using the currency's decimal places.
    static func formatAmount(_ amount: Int, currency: String) -> String {
        let places = decimals(of: currency)
        let plain = plainDecimal(rounded(amount, currency: currency), scaleDigits: 4, minFraction: 4)
        let parts = plain.split(separator: ".", omittingEmptySubsequences: false)
        let negative = parts[0].hasPrefix("-")
        let digits = Array(negative ? parts[0].dropFirst() : parts[0][...])
        var grouped = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { grouped.append(",") }
            grouped.append(digit)
        }
        let sign = negative ? "-" : ""
        guard places > 0 else { return "\(sign)\(grouped)" }
        return "\(sign)\(grouped).\(parts[1].prefix(places))"
    }

    static func format(_ amount: Int, _ currency: String) -> String {
        "\(formatAmount(amount, currency: currency)) \(currency)"
    }

    private static func parseScaled(_ input: String, scaleDigits: Int) -> Int? {
        let cleaned = input.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        let negative = cleaned.hasPrefix("-")
        let body = negative ? String(cleaned.dropFirst()) : cleaned
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let whole = String(parts[0])
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        guard !(whole.isEmpty && fraction.isEmpty), fraction.count <= scaleDigits else { return nil }
        guard (whole + fraction).allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let padded = fraction + String(repeating: "0", count: scaleDigits - fraction.count)
        guard let value = Int((whole.isEmpty ? "0" : whole) + padded), value <= 9_007_199_254_740_991
        else { return nil }
        return negative ? -value : value
    }

    /// Parses "1,234.567" to a scaled amount. Returns nil if it is not a number.
    static func parseAmount(_ input: String) -> Int? { parseScaled(input, scaleDigits: 4) }
    /// The same, and also nil if it has more decimals than the currency allows.
    static func parseAmount(_ input: String, currency: String) -> Int? {
        guard let amount = parseAmount(input) else { return nil }
        var step = 1
        for _ in 0..<(4 - decimals(of: currency)) { step *= 10 }
        return amount % step == 0 ? amount : nil
    }

    static func parseFxRate(_ input: String) -> Int? { parseScaled(input, scaleDigits: 8) }
    static func parsePercent(_ input: String) -> Int? { parseScaled(input, scaleDigits: 4) }
}
