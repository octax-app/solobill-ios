import Foundation

/// What the owner must fill in before a renewal draft can be issued. Empty when it is ready.
/// Every field holds typed text, and only `input(for:)` turns it into scaled integers.
struct RenewalEdits: Equatable {
    struct Amount: Identifiable, Equatable {
        /// The line's place in the draft. Saving replaces the lines, so their ids change.
        let index: Int
        let description: String
        var quantity: String
        var unitPrice: String

        var id: Int { index }
    }

    struct CostRate: Identifiable, Equatable {
        let currency: String
        var text = ""

        var id: String { currency }
    }

    var amounts: [Amount]
    /// Nil unless the draft has no exchange rate.
    var fxRate: String?
    /// One per cost currency with no rate, however many lines use it.
    var costRates: [CostRate]

    init(draft: InvoiceFull) {
        amounts = draft.lines.enumerated().compactMap { index, line in
            guard !line.amountConfirmed else { return nil }
            return Amount(
                index: index,
                description: line.description,
                quantity: Money.amountInput(line.quantity),
                unitPrice: Money.amountInput(line.unitPrice)
            )
        }
        fxRate = draft.fxRate <= 0 ? "" : nil
        let missing = draft.lines.filter { $0.costFxRate <= 0 }.map(\.costCurrency)
        costRates = Set(missing).sorted().map { CostRate(currency: $0) }
    }

    var isEmpty: Bool { amounts.isEmpty && fxRate == nil && costRates.isEmpty }

    /// The draft with only these fields changed, or nil if something typed is not valid.
    func input(for draft: InvoiceFull) -> InvoiceInput? {
        var input = InvoiceInput(draft: draft)
        if let fxRate {
            guard let rate = Self.positiveRate(fxRate) else { return nil }
            input.fxRate = rate
        }
        for amount in amounts {
            guard let quantity = Money.parseAmount(amount.quantity), quantity > 0,
                  let unitPrice = Money.parseAmount(amount.unitPrice), unitPrice >= 0
            else { return nil }
            input.lines[amount.index].quantity = quantity
            input.lines[amount.index].unitPrice = unitPrice
            input.lines[amount.index].amountConfirmed = true
        }
        for cost in costRates {
            guard let rate = Self.positiveRate(cost.text) else { return nil }
            for index in input.lines.indices
            where input.lines[index].costCurrency == cost.currency && input.lines[index].costFxRate <= 0 {
                input.lines[index].costFxRate = rate
            }
        }
        return input
    }

    private static func positiveRate(_ text: String) -> Int? {
        guard let rate = Money.parseFxRate(text), rate > 0 else { return nil }
        return rate
    }
}
