import SwiftUI

/// One payment spread over the customer's open invoices, oldest first, with the split shown before
/// saving. Only invoices in the chosen currency are considered.
struct CustomerPaymentSheet: View {
    let invoices: [InvoiceRow]
    let confirm: @MainActor (CustomerPaymentInput) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var currency: String
    @State private var amount = ""
    @State private var date = Date.now
    @State private var note = ""
    @State private var working = false
    @State private var message: String?

    init(
        customer: Customer,
        invoices: [InvoiceRow],
        confirm: @escaping @MainActor (CustomerPaymentInput) async throws -> Void
    ) {
        self.invoices = invoices
        self.confirm = confirm
        _currency = State(initialValue: customer.currency)
    }

    private var open: [InvoiceRow] {
        invoices.filter {
            $0.type == .invoice && $0.status == .issued && $0.currency == currency && $0.due > 0
        }
    }

    private var entry: PaymentEntry {
        PaymentEntry(
            amount,
            kind: .payment,
            due: open.map(\.due).reduce(0, +),
            currency: currency
        )
    }

    private var split: PaymentSplit {
        PaymentSplit.allocate(
            entry.amount ?? 0,
            open: open.map { .init(id: $0.id, issuedOn: $0.issuedOn, due: $0.due) }
        )
    }

    private func number(of invoiceID: Int) -> String {
        open.first { $0.id == invoiceID }?.number ?? "No number"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Currency", selection: $currency) {
                        ForEach(Money.currencyCodes, id: \.self) { Text($0).tag($0) }
                    }
                    .accessibilityIdentifier("customerPayment.currency")
                    TextField("Amount in \(currency)", text: $amount)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("customerPayment.amount")
                    DatePicker("Paid on", selection: $date, in: ...Date.now, displayedComponents: .date)
                    TextField("Note", text: $note, axis: .vertical)
                        .accessibilityIdentifier("customerPayment.note")
                } footer: {
                    if let problem = entry.problem {
                        Text(problem)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("customerPayment.problem")
                    }
                }
                splitSection
                if let message {
                    Section {
                        Text(message)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("customerPayment.message")
                    }
                }
            }
            .navigationTitle("Add payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(working || open.isEmpty || entry.amount == nil)
                    .accessibilityIdentifier("customerPayment.save")
                }
            }
        }
    }

    @ViewBuilder private var splitSection: some View {
        if open.isEmpty {
            Section {
                Text("This customer has no open invoices in \(currency).")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("customerPayment.noOpen")
            }
        } else if !split.allocations.isEmpty {
            Section("Goes to, oldest first") {
                ForEach(split.allocations, id: \.invoiceId) { allocation in
                    LabeledContent(number(of: allocation.invoiceId)) {
                        Text(Money.format(allocation.amount, currency))
                            .monospacedDigit()
                            .accessibilityIdentifier("customerPayment.split.\(allocation.invoiceId)")
                    }
                }
                if split.excess > 0, let last = split.allocations.last {
                    Text(
                        "\(Money.format(split.excess, currency)) extra stays on \(number(of: last.invoiceId)) and counts as profit"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("customerPayment.excess")
                }
            }
        }
    }

    private func save() async {
        guard let value = entry.amount else { return }
        working = true
        defer { working = false }
        do {
            try await confirm(
                CustomerPaymentInput(
                    currency: currency,
                    amount: value,
                    paidOn: ISODay.string(from: date),
                    note: note.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }
}
