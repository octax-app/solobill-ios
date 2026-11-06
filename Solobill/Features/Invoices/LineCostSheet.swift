import SwiftUI

/// Edits the internal cost of one invoice line. Cost stays editable after issue, because nothing
/// here appears on the document.
struct LineCostSheet: View {
    let invoiceID: Int
    let line: InvoiceLine
    let onSaved: @Sendable () async -> Void

    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss

    private struct Loaded: Sendable {
        let baseCurrency: String
        let options: [OriginalLineOption]
    }

    var body: some View {
        let api = api
        NavigationStack {
            Loadable {
                async let settings = api.settings()
                async let options = api.originalLines()
                return try await Loaded(baseCurrency: settings.baseCurrency, options: options)
            } content: { loaded, _ in
                LineCostForm(
                    invoiceID: invoiceID,
                    line: line,
                    baseCurrency: loaded.baseCurrency,
                    options: loaded.options,
                    onSaved: onSaved
                )
            }
            .navigationTitle("Edit cost")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("cost.cancel")
                }
            }
        }
    }
}

private struct LineCostForm: View {
    let invoiceID: Int
    let line: InvoiceLine
    let baseCurrency: String
    let options: [OriginalLineOption]
    let onSaved: @Sendable () async -> Void

    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss

    @State private var linkedID: Int?
    @State private var amount: String
    @State private var currency: String
    @State private var rate: String
    @State private var isSaving = false
    @State private var message: String?

    init(
        invoiceID: Int,
        line: InvoiceLine,
        baseCurrency: String,
        options: [OriginalLineOption],
        onSaved: @escaping @Sendable () async -> Void
    ) {
        self.invoiceID = invoiceID
        self.line = line
        self.baseCurrency = baseCurrency
        self.options = options
        self.onSaved = onSaved
        _linkedID = State(initialValue: line.originalInvoiceLineId)
        _amount = State(initialValue: Money.amountInput(line.costAmount))
        _currency = State(initialValue: line.costCurrency)
        _rate = State(initialValue: line.costFxRate > 0 ? Money.fxRateInput(line.costFxRate) : "")
    }

    var body: some View {
        Form {
            Section {
                Text(line.description)
            } header: {
                Text("Line")
            } footer: {
                Text("Your cost is internal and is never printed. The issued document does not change.")
            }
            Section {
                Picker("Original invoice line", selection: $linkedID) {
                    Text("Not linked").tag(Int?.none)
                    ForEach(options) { Text($0.label).tag(Int?.some($0.id)) }
                }
                .pickerStyle(.navigationLink)
                .accessibilityIdentifier("cost.original")
            }
            Section {
                LabeledContent("Cost") {
                    TextField("0", text: $amount)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("cost.amount")
                }
                Picker("Currency", selection: $currency) {
                    ForEach(Money.currencyCodes, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.navigationLink)
                .accessibilityIdentifier("cost.currency")
                if currency != baseCurrency {
                    LabeledContent("1 \(currency) in \(baseCurrency)") {
                        TextField("Type the rate", text: $rate)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("cost.rate")
                    }
                }
            }
            Section {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving { ProgressView() } else { Text("Save cost") }
                }
                .disabled(isSaving)
                .accessibilityIdentifier("cost.save")
                if let message {
                    Text(message)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("cost.error")
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: linkedID) { fillFromLinkedLine() }
        .onChange(of: currency) { rate = "" }
        .task(id: currency) { await prefillRate() }
    }

    /// The linked line's total becomes the cost, as on the web.
    private func fillFromLinkedLine() {
        guard let match = options.first(where: { $0.id == linkedID }) else { return }
        amount = Money.amountInput(match.total)
        currency = match.currency
    }

    private func prefillRate() async {
        guard currency != baseCurrency, rate.isEmpty else { return }
        let code = currency
        guard let last = try? await api.lastFxRate(currency: code) else { return }
        if currency == code, rate.isEmpty { rate = Money.fxRateInput(last) }
    }

    private func parsedRate() -> Int? {
        if currency == baseCurrency { return Money.fxScale }
        guard let value = Money.parseFxRate(rate), value > 0 else { return nil }
        return value
    }

    private func save() async {
        guard let cost = Money.parseAmount(amount), cost >= 0 else {
            message = "Enter the cost"
            return
        }
        guard let costRate = parsedRate() else {
            message = "Enter the exchange rate for \(currency)"
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try await api.updateLineCost(
                invoiceId: invoiceID,
                lineId: line.id,
                LineCostInput(
                    costAmount: cost,
                    costCurrency: currency,
                    costFxRate: costRate,
                    originalInvoiceLineId: linkedID
                )
            )
            await onSaved()
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }
}
