import SwiftUI

/// One line of the invoice and proforma form. `position` numbers the fields from zero for UI tests.
struct DocumentLineSection: View {
    @Binding var line: DocumentLine
    let idPrefix: String
    let position: Int
    let formCurrency: String
    let baseCurrency: String
    let onRemove: () -> Void

    @Environment(\.api) private var api

    var body: some View {
        Section {
            TextField("Description", text: $line.description, axis: .vertical)
                .accessibilityIdentifier(field("description"))
            if !line.amountConfirmed {
                Toggle("Amount confirmed", isOn: $line.amountConfirmed)
                    .accessibilityIdentifier(field("confirmed"))
            }
            LabeledContent("Quantity") {
                TextField("1", text: $line.quantity)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier(field("quantity"))
            }
            LabeledContent("Unit price (\(formCurrency))") {
                TextField("0", text: $line.unitPrice)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier(field("price"))
            }
            if let hint = line.priceHint(formCurrency: formCurrency) {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(field("priceHint"))
            }
            LabeledContent("Your cost") {
                TextField("0", text: $line.costAmount)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier(field("cost"))
            }
            Picker("Cost currency", selection: $line.costCurrency) {
                ForEach(Money.currencyCodes, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.navigationLink)
            .accessibilityIdentifier(field("costCurrency"))
            if line.costCurrency != baseCurrency {
                LabeledContent("1 \(line.costCurrency) in \(baseCurrency)") {
                    TextField("Type the rate", text: $line.costFxRate)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier(field("costRate"))
                }
            }
            Button("Remove line", role: .destructive, action: onRemove)
                .accessibilityIdentifier(field("remove"))
        } header: {
            Text("Line \(position + 1)")
        } footer: {
            Text("Your cost is internal and is never printed.")
        }
        .onChange(of: line.costCurrency) { line.costFxRate = "" }
        .task(id: line.costCurrency) { await prefillRate() }
    }

    private func field(_ name: String) -> String { "\(idPrefix).line.\(position).\(name)" }

    /// Leaves the field empty when there is no rate yet, so the owner is asked to type it.
    private func prefillRate() async {
        guard line.costCurrency != baseCurrency, line.costFxRate.isEmpty else { return }
        let currency = line.costCurrency
        guard let rate = try? await api.lastFxRate(currency: currency) else { return }
        if line.costCurrency == currency, line.costFxRate.isEmpty {
            line.costFxRate = Money.fxRateInput(rate)
        }
    }
}
