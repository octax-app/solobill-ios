import SwiftUI

/// Reviews one renewal draft, following the renewal behaviour of the web invoice page.
struct RenewalReviewScreen: View {
    let invoiceID: Int
    let customerName: String

    @Environment(\.api) private var api

    private struct Review: Sendable {
        let invoice: InvoiceFull
        let baseCurrency: String
    }

    var body: some View {
        Loadable(load: { [api, invoiceID] in
            async let invoice = api.invoice(id: invoiceID)
            async let settings = api.settings()
            return try await Review(invoice: invoice, baseCurrency: settings.baseCurrency)
        }) { review, reload in
            RenewalReviewContent(
                invoice: review.invoice,
                baseCurrency: review.baseCurrency,
                customerName: customerName,
                reload: reload
            )
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct RenewalReviewContent: View {
    let invoice: InvoiceFull
    let baseCurrency: String
    let customerName: String
    let reload: @Sendable () async -> Void

    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss
    @State private var edits: RenewalEdits
    @State private var working = false
    @State private var confirmingIssue = false
    @State private var confirmingDiscard = false
    @State private var failure: String?

    init(
        invoice: InvoiceFull,
        baseCurrency: String,
        customerName: String,
        reload: @escaping @Sendable () async -> Void
    ) {
        self.invoice = invoice
        self.baseCurrency = baseCurrency
        self.customerName = customerName
        self.reload = reload
        _edits = State(initialValue: RenewalEdits(draft: invoice))
    }

    private var isDraft: Bool { invoice.status == .draft }
    private var totalText: String { Money.format(invoice.total, invoice.currency) }

    var body: some View {
        List {
            summary
            Section("Lines") {
                ForEach(invoice.lines) { line in
                    RenewalLineRow(line: line, currency: invoice.currency)
                }
            }
            if isDraft && !edits.isEmpty { entry }
            totals
            Section {
                pdfLink
            }
            if isDraft { actions }
        }
        .navigationTitle(invoice.number ?? "Renewal draft")
        .scrollDismissesKeyboard(.immediately)
        .refreshable { await reload() }
        .disabled(working)
        .overlay {
            if working { ProgressView().controlSize(.large) }
        }
        .onChange(of: invoice) { edits = RenewalEdits(draft: invoice) }
        .alert("Issue this invoice?", isPresented: $confirmingIssue) {
            Button("Issue invoice") { run { _ = try await api.issue(id: invoice.id) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(totalText) to \(customerName). An issued invoice cannot be changed, only voided.")
        }
        .alert("Discard this renewal?", isPresented: $confirmingDiscard) {
            Button("Discard renewal", role: .destructive) {
                run {
                    try await api.void(id: invoice.id)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The draft is voided and the subscription moves to its next renewal date.")
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private var summary: some View {
        Section {
            LabeledContent("Customer", value: customerName)
            LabeledContent("Status") {
                Text(invoice.status.label).accessibilityIdentifier("renewal.status")
            }
            if let number = invoice.number {
                LabeledContent("Number") {
                    Text(number).accessibilityIdentifier("renewal.number")
                }
            }
            if let issuedOn = invoice.issuedOn {
                LabeledContent("Issued on", value: ISODay.display(issuedOn))
            }
            LabeledContent("Due on", value: ISODay.display(invoice.dueOn))
        }
    }

    private var entry: some View {
        Section {
            ForEach($edits.amounts) { $amount in
                if edits.amounts.count > 1 {
                    Text(amount.description).font(.subheadline)
                }
                EntryRow(label: "Quantity", text: $amount.quantity, id: "renewal.quantity.\(amount.index)")
                EntryRow(
                    label: "Unit price (\(invoice.currency))",
                    text: $amount.unitPrice,
                    id: "renewal.unitPrice.\(amount.index)"
                )
            }
            if let fxRate = edits.fxRate {
                EntryRow(
                    label: "1 \(invoice.currency) in \(baseCurrency)",
                    text: Binding(get: { fxRate }, set: { edits.fxRate = $0 }),
                    id: "renewal.fxRate"
                )
            }
            ForEach($edits.costRates) { $cost in
                EntryRow(
                    label: "Cost: 1 \(cost.currency) in \(baseCurrency)",
                    text: $cost.text,
                    id: "renewal.costRate.\(cost.currency)"
                )
            }
            Button(edits.amounts.isEmpty ? "Save rates" : "Confirm and save") {
                guard let input = edits.input(for: invoice) else { return }
                run { _ = try await api.updateDraft(id: invoice.id, input) }
            }
            .disabled(edits.input(for: invoice) == nil)
            .accessibilityIdentifier("renewal.save")
        } header: {
            Text(edits.amounts.isEmpty ? "Exchange rates" : "Confirm the amount")
        } footer: {
            Text(entryHelp)
        }
    }

    private var entryHelp: String {
        var parts: [String] = []
        if !edits.amounts.isEmpty {
            parts.append("This amount is based on the last bill. Update it or accept it before issuing.")
        }
        if edits.fxRate != nil || !edits.costRates.isEmpty {
            parts.append("Type each missing rate. It is locked on this invoice.")
        }
        return parts.joined(separator: " ")
    }

    private var totals: some View {
        Section("Totals") {
            LabeledContent("Subtotal", value: Money.format(invoice.subtotal, invoice.currency))
            if invoice.taxEnabled {
                LabeledContent("Tax", value: Money.format(invoice.tax, invoice.currency))
            }
            LabeledContent("Total") {
                Text(totalText)
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("renewal.total")
            }
        }
        .monospacedDigit()
    }

    private var pdfLink: some View {
        NavigationLink {
            PDFScreen(
                title: invoice.number ?? "Draft preview",
                filename: invoice.number ?? "Draft preview",
                load: { [api, id = invoice.id] in try await api.invoicePDF(id: id) }
            )
        } label: {
            Label(isDraft ? "Preview PDF" : "View PDF", systemImage: "doc.text")
        }
        .accessibilityIdentifier("renewal.pdf")
    }

    private var actions: some View {
        Section {
            Button("Issue invoice") { confirmingIssue = true }
                .disabled(!edits.isEmpty)
                .accessibilityIdentifier("renewal.issue")
            Button("Discard renewal", role: .destructive) { confirmingDiscard = true }
                .accessibilityIdentifier("renewal.discard")
        } footer: {
            if !edits.isEmpty {
                Text("Complete the section above to issue this invoice.")
            }
        }
    }

    /// Runs one server action, then shows what the server now holds. Nothing is calculated here.
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        working = true
        Task {
            defer { working = false }
            do {
                try await action()
                await reload()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

private struct RenewalLineRow: View {
    let line: InvoiceLine
    let currency: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(line.description)
            HStack(alignment: .firstTextBaseline) {
                Text("\(Money.amountInput(line.quantity)) × \(Money.format(line.unitPrice, currency))")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Money.format(line.total, currency))
            }
            .font(.subheadline)
            .monospacedDigit()
            Text("Cost (internal): \(Money.format(line.costAmount, line.costCurrency))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !line.amountConfirmed {
                Label("Amount not confirmed", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct EntryRow: View {
    let label: String
    @Binding var text: String
    let id: String

    var body: some View {
        LabeledContent(label) {
            TextField(label, text: $text)
                // `.decimalPad` offers only a comma in some regions, and the money parser reads a
                // comma as a thousands separator, so "12,5" would save as 125.
                .keyboardType(.numbersAndPunctuation)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier(id)
        }
    }
}
