import SwiftUI

/// Checks a typed amount before it reaches the server.
struct PaymentEntry: Equatable {
    /// Nil while nothing can be saved.
    let amount: Int?
    /// Why the amount cannot be saved. Nil when it can, or when the field is still empty.
    let problem: String?
    /// How much a payment goes beyond what is due.
    let extra: Int

    /// `discount` sets the most a discount can be. Without it, that is the due.
    init(_ text: String, kind: PaymentKind, due: Int, currency: String, discount: DiscountTerms? = nil) {
        let limit = discount?.limit ?? due
        var amount: Int?
        var problem: String?
        var extra = 0
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            // Nothing typed yet, so there is nothing to complain about.
        } else if let parsed = Money.parseAmount(text, currency: currency) {
            if parsed <= 0 {
                problem = "Enter an amount above 0."
            } else if kind == .discount, parsed > limit {
                let basis = discount?.taxEnabled == true ? " before tax" : ""
                problem = "The discount cannot be more than \(Money.format(limit, currency))\(basis)."
            } else {
                amount = parsed
                extra = max(0, parsed - due)
            }
        } else {
            problem = "Enter an amount with up to \(Money.decimals(of: currency)) decimals."
        }
        self.amount = amount
        self.problem = problem
        self.extra = extra
    }
}

/// Adds a payment or a discount to one invoice. The amount starts as all that can be entered, so
/// a discount can close a partly paid invoice in one step. A discount is typed before tax, and
/// prints on the PDF. Present it with `.sheet`.
struct PaymentSheet: View {
    let kind: PaymentKind
    let title: String
    let currency: String
    let due: Int
    var discount: DiscountTerms?
    let confirm: @MainActor (PaymentInput) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var amount: String
    @State private var date = Date.now
    @State private var note = ""
    @State private var working = false
    @State private var message: String?

    init(
        kind: PaymentKind,
        title: String,
        currency: String,
        due: Int,
        discount: DiscountTerms? = nil,
        confirm: @escaping @MainActor (PaymentInput) async throws -> Void
    ) {
        self.kind = kind
        self.title = title
        self.currency = currency
        self.due = due
        self.discount = discount
        self.confirm = confirm
        let start = discount?.limit ?? due
        _amount = State(initialValue: start > 0 ? Money.amountInput(start) : "")
    }

    private var entry: PaymentEntry {
        PaymentEntry(amount, kind: kind, due: due, currency: currency, discount: discount)
    }

    private var isTaxedDiscount: Bool { kind == .discount && discount?.taxEnabled == true }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Invoice", value: title)
                    LabeledContent("Due", value: Money.format(due, currency))
                        .monospacedDigit()
                    TextField(isTaxedDiscount ? "Amount before tax in \(currency)" : "Amount in \(currency)", text: $amount)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("payment.amount")
                    DatePicker(
                        kind == .payment ? "Paid on" : "Date",
                        selection: $date,
                        in: ...Date.now,
                        displayedComponents: .date
                    )
                    TextField("Note", text: $note, axis: .vertical)
                        .accessibilityIdentifier("payment.note")
                } footer: {
                    if let problem = entry.problem {
                        Text(problem)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("payment.problem")
                    } else if isTaxedDiscount, let value = entry.amount, let discount {
                        Text("Before tax. \(Money.format(discount.withTax(value), currency)) comes off the amount due.")
                            .accessibilityIdentifier("payment.offDue")
                    } else if entry.extra > 0 {
                        Text("\(Money.format(entry.extra, currency)) extra counts as profit")
                            .accessibilityIdentifier("payment.extra")
                    }
                }
                if let message {
                    Section {
                        Text(message)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("payment.message")
                    }
                }
            }
            .navigationTitle(kind == .payment ? "Add payment" : "Add discount")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(working || entry.amount == nil)
                    .accessibilityIdentifier("payment.save")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() async {
        guard let value = entry.amount else { return }
        working = true
        defer { working = false }
        do {
            try await confirm(
                PaymentInput(
                    kind: kind,
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
