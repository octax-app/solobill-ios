import Testing

@testable import Solobill

@Suite struct MoneyTests {
    @Test func formatsWithTheCurrencysOwnDecimals() {
        #expect(Money.format(12_345_000, "USD") == "1,234.50 USD")
        #expect(Money.format(12_345_000, "OMR") == "1,234.500 OMR")
        #expect(Money.format(10_000, "KWD") == "1.000 KWD")
        #expect(Money.format(0, "BHD") == "0.000 BHD")
    }

    @Test func groupsThousandsAndKeepsTheSign() {
        #expect(Money.formatAmount(12_345_678_900_000, currency: "USD") == "1,234,567,890.00")
        #expect(Money.formatAmount(-10_000_000, currency: "USD") == "-1,000.00")
        #expect(Money.formatAmount(-5_000, currency: "USD") == "-0.50")
    }

    @Test func roundsHalfAwayFromZeroForDisplay() {
        #expect(Money.formatAmount(12_350, currency: "USD") == "1.24")
        #expect(Money.formatAmount(-12_350, currency: "USD") == "-1.24")
        #expect(Money.formatAmount(12_349, currency: "USD") == "1.23")
        #expect(Money.formatAmount(12_345, currency: "OMR") == "1.235")
    }

    @Test func parsesTypedAmounts() {
        #expect(Money.parseAmount("1,234.567") == 12_345_670)
        #expect(Money.parseAmount("0.5") == 5_000)
        #expect(Money.parseAmount(".5") == 5_000)
        #expect(Money.parseAmount("5.") == 50_000)
        #expect(Money.parseAmount("-2") == -20_000)
        #expect(Money.parseAmount(" 12 ") == 120_000)
    }

    @Test func rejectsInputThatIsNotANumber() {
        #expect(Money.parseAmount("") == nil)
        #expect(Money.parseAmount(".") == nil)
        #expect(Money.parseAmount("abc") == nil)
        #expect(Money.parseAmount("1.2.3") == nil)
        #expect(Money.parseAmount("1.23456") == nil)
        #expect(Money.parseAmount("٣") == nil)
    }

    @Test func parsesRatesAndPercentagesAtTheirOwnScale() {
        #expect(Money.parseFxRate("2.6") == 260_000_000)
        #expect(Money.parseFxRate("1.123456789") == nil)
        #expect(Money.parsePercent("5") == 50_000)
    }

    @Test func inputTextRoundTrips() {
        #expect(Money.amountInput(12_345_000) == "1234.5")
        #expect(Money.amountInput(50_000) == "5")
        #expect(Money.fxRateInput(260_000_000) == "2.6")
        #expect(Money.percentText(50_000) == "5")
        #expect(Money.parseAmount(Money.amountInput(12_345_678)) == 12_345_678)
    }
}
