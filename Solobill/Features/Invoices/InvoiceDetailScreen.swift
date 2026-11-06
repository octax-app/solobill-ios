import SwiftUI

/// One customer invoice or proforma. Other features push this. A manual draft shows its review
/// instead, which edits and issues it, and a renewal draft links to the renewal review.
struct InvoiceDetailScreen: View {
    let invoiceID: Int

    @Environment(\.api) private var api
    @State private var markingPaid = false
    @State private var entering: PaymentKind?
    @State private var removing: Payment?
    @State private var working = false
    @State private var message: String?
    @State private var confirmingVoid = false
    @State private var confirmingReverse = false
    @State private var confirmingUndo = false
    @State private var costLine: InvoiceLine?
    /// The draft invoice from converting a proforma, which opens in the editor.
    @State private var convertedDraft: Invoice?
    /// Set after issuing that draft, to open the issued invoice.
    @State private var issuedID: Int?

    private struct Details: Sendable {
        let invoice: InvoiceFull
        let customer: Customer
    }

    var body: some View {
        Loadable(id: invoiceID) { [api, invoiceID] in
            let invoice = try await api.invoice(id: invoiceID)
            return Details(invoice: invoice, customer: try await api.customer(id: invoice.customerId))
        } content: { details, reload in
            Group {
                if details.invoice.status == .draft, details.invoice.source == .manual {
                    DocumentReviewContent(
                        invoice: details.invoice,
                        customer: details.customer,
                        reload: reload,
                        // Issuing a duplicate reports the copy, so this draft stays as it is.
                        onIssued: { issued in
                            if issued.id == invoiceID { Task { await reload() } } else { issuedID = issued.id }
                        }
                    )
                } else {
                    content(details, reload: reload)
                }
            }
            .refreshable { await reload() }
            .navigationTitle(title(of: details.invoice))
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $issuedID) { id in
            InvoiceDetailScreen(invoiceID: id)
        }
    }

    private func title(of invoice: InvoiceFull) -> String {
        invoice.number ?? (invoice.type == .proforma ? "Draft proforma" : "Draft invoice")
    }

    private func content(_ details: Details, reload: @escaping @Sendable () async -> Void) -> some View {
        let invoice = details.invoice
        return List {
            Section {
                LabeledContent("Customer", value: details.customer.displayName)
                LabeledContent("Type", value: invoice.type.rawValue.capitalized)
                LabeledContent("Status") { StatusText(invoice).accessibilityIdentifier("invoice.status") }
                if let issuedOn = invoice.issuedOn { LabeledContent("Issued", value: ISODay.display(issuedOn)) }
                if let dueOn = invoice.dueOn { LabeledContent("Due on", value: ISODay.display(dueOn)) }
                if let validUntil = invoice.validUntil {
                    LabeledContent("Valid until", value: ISODay.display(validUntil))
                }
                if let paidOn = invoice.paidOn { LabeledContent("Paid on", value: ISODay.display(paidOn)) }
                if invoice.source == .renewal { LabeledContent("Source", value: "Renewal") }
            }

            Section("Lines and internal cost") {
                ForEach(invoice.lines) { line in
                    VStack(alignment: .leading, spacing: 4) {
                        LineRow(
                            description: line.description,
                            caption: captions(for: line, currency: invoice.currency),
                            amount: Money.format(line.net, invoice.currency)
                        )
                        if invoice.status != .draft {
                            Button("Edit cost") { costLine = line }
                                .font(.caption)
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("invoice.line.\(line.position).editCost")
                        }
                    }
                }
            }

            Section {
                let totals = invoice.discountedTotals
                total("Subtotal", invoice.subtotal, invoice.currency)
                if totals.discount > 0 { total("Discount", -totals.discount, invoice.currency) }
                if invoice.taxEnabled { total("Tax", totals.tax, invoice.currency) }
                total("Total", totals.total, invoice.currency).bold()
                balances(invoice)
            }

            if invoice.type == .invoice, !invoice.payments.isEmpty {
                paymentsSection(invoice)
            }

            if !invoice.notes.isEmpty {
                Section("Notes") { Text(invoice.notes) }
            }

            Section {
                NavigationLink {
                    PDFScreen(title: title(of: invoice), filename: invoice.number ?? "Draft") { [api, invoiceID] in
                        try await api.invoicePDF(id: invoiceID)
                    }
                } label: {
                    Label("View PDF", systemImage: "doc.richtext")
                }
                .accessibilityIdentifier("invoice.pdf")

                actions(invoice)
                documentActions(details, reload: reload)
            }

            if let message {
                Section { Text(message).foregroundStyle(.red) }
            }
        }
        .sheet(isPresented: $markingPaid) {
            MarkPaidSheet(
                title: title(of: invoice),
                amount: Money.format(invoice.due, invoice.currency)
            ) { day in
                try await api.markPaid(invoiceId: invoice.id, on: day)
                await reload()
            }
        }
        .sheet(item: $costLine) { line in
            LineCostSheet(invoiceID: invoice.id, line: line, onSaved: reload)
        }
        .sheet(item: $convertedDraft, onDismiss: { Task { await reload() } }) { draft in
            DocumentEditorSheet(mode: .edit(draft.type, id: draft.id)) { issued in
                convertedDraft = nil
                issuedID = issued.id
            }
        }
        .alert("Undo paid?", isPresented: $confirmingUndo) {
            Button("Undo paid", role: .destructive) {
                Task { await undoPaid(reload: reload) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(undoMessage(invoice))
        }
        .alert("Reverse this document?", isPresented: $confirmingReverse) {
            Button("Reverse document", role: .destructive) {
                Task { await reverse(reload: reload) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It goes back to draft and keeps its number. Its stored PDF is deleted and cannot be recovered, so any copy already sent stays the only one.")
        }
        .alert("Void this document?", isPresented: $confirmingVoid) {
            Button("Void document", role: .destructive) {
                Task { await void(reload: reload) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its number stays used and it no longer counts toward any totals. This cannot be undone.")
        }
        .sheet(item: $entering) { kind in
            PaymentSheet(
                kind: kind,
                title: title(of: invoice),
                currency: invoice.currency,
                due: invoice.due,
                discount: kind == .discount ? invoice.discountTerms : nil
            ) { input in
                try await api.addPayment(invoiceId: invoice.id, input)
                await reload()
            }
        }
        .alert(
            removing.map(removalTitle) ?? "",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { payment in
            Button("Remove", role: .destructive) {
                Task { await remove(payment, reload: reload) }
            }
            .accessibilityIdentifier("payment.delete.confirm")
            Button("Cancel", role: .cancel) {}
        } message: { payment in
            Text(removalMessage(payment))
        }
    }

    /// Paid and overpaid only appear once they apply. Due stays for any invoice that
    /// was issued, and a voided one owes nothing.
    @ViewBuilder
    private func balances(_ invoice: InvoiceFull) -> some View {
        if invoice.type == .invoice {
            if invoice.paidAmount > 0 { total("Paid", invoice.paidAmount, invoice.currency) }
            if invoice.status == .issued || invoice.status == .paid {
                total("Due", invoice.due, invoice.currency).bold()
            }
            if invoice.overpaid > 0 { total("Overpaid", invoice.overpaid, invoice.currency) }
        }
    }

    private func paymentsSection(_ invoice: InvoiceFull) -> some View {
        Section("Payments") {
            ForEach(invoice.payments) { payment in
                // Rows on a voided invoice are kept as history and cannot be removed.
                PaymentRow(
                    payment: payment,
                    currency: invoice.currency,
                    remove: invoice.status == .issued || invoice.status == .paid ? { removing = payment } : nil
                )
                .disabled(working)
            }
        }
    }

    private func removalTitle(_ payment: Payment) -> String {
        payment.kind == .discount ? "Remove this discount?" : "Remove this payment?"
    }

    private func removalMessage(_ payment: Payment) -> String {
        if payment.groupId != nil {
            return "This was one customer payment, so the whole payment is removed from every invoice it was split across."
        }
        return "What is due and the invoice status will update."
    }

    private func captions(for line: InvoiceLine, currency: String) -> [String] {
        var captions = ["\(Money.amountInput(line.quantity)) × \(Money.format(line.unitPrice, currency))"]
        if line.costAmount != 0 {
            captions.append("Cost \(Money.format(line.costAmount, line.costCurrency))")
        }
        return captions
    }

    private func total(_ label: String, _ amount: Int, _ currency: String) -> some View {
        LabeledContent(label, value: Money.format(amount, currency))
            .monospacedDigit()
            .accessibilityIdentifier("invoice.\(label.lowercased())")
    }

    /// Proformas are never paid. Only an issued invoice takes payments, as on the web. A payment is
    /// undone by removing it from the payments list.
    @ViewBuilder
    private func actions(_ invoice: InvoiceFull) -> some View {
        if invoice.type == .invoice, invoice.status == .issued {
            Button("Add payment") { entering = .payment }
                .accessibilityIdentifier("invoice.addPayment")
            if invoice.due > 0 {
                Button("Discount") { entering = .discount }
                    .accessibilityIdentifier("invoice.addDiscount")
            }
            Button("Mark as paid") { markingPaid = true }
                .accessibilityIdentifier("invoice.markPaid")
        }
    }

    /// Nothing on an issued document can be edited. A mistake is fixed by reversing it to draft, or
    /// by voiding and reissuing. Reversing is only offered while no payment is recorded.
    @ViewBuilder
    private func documentActions(_ details: Details, reload: @escaping @Sendable () async -> Void) -> some View {
        let invoice = details.invoice
        if invoice.status == .draft, invoice.source == .renewal {
            NavigationLink("Review renewal") {
                RenewalReviewScreen(invoiceID: invoice.id, customerName: details.customer.displayName)
            }
            .accessibilityIdentifier("invoice.reviewRenewal")
        }
        if invoice.type == .proforma, invoice.status == .issued {
            Button("Convert to invoice") {
                Task { await convert(reload: reload) }
            }
            .disabled(working)
            .accessibilityIdentifier("invoice.convert")
        }
        if invoice.status == .paid {
            Button("Undo paid", role: .destructive) { confirmingUndo = true }
                .disabled(working)
                .accessibilityIdentifier("invoice.undoPaid")
        }
        if invoice.status == .issued, invoice.payments.isEmpty {
            Button("Reverse", role: .destructive) { confirmingReverse = true }
                .disabled(working)
                .accessibilityIdentifier("invoice.reverse")
        }
        if invoice.status == .issued || invoice.status == .paid {
            Button("Void", role: .destructive) { confirmingVoid = true }
                .disabled(working)
                .accessibilityIdentifier("invoice.void")
        }
        DuplicateDocumentButton(invoiceID: invoice.id) { issuedID = $0.id }
    }

    private func undoMessage(_ invoice: InvoiceFull) -> String {
        let message = "Every payment and discount on this invoice is removed and it goes back to issued with nothing paid."
        guard invoice.payments.contains(where: { $0.groupId != nil }) else { return message }
        return "\(message) A customer payment is removed from every invoice it was split across."
    }

    /// A refusal shows the server's message. Reverse is offered again after the reload.
    private func undoPaid(reload: @Sendable () async -> Void) async {
        working = true
        defer { working = false }
        do {
            _ = try await api.undoPayments(id: invoiceID)
            message = nil
            await reload()
        } catch {
            message = error.localizedDescription
        }
    }

    private func convert(reload: @Sendable () async -> Void) async {
        working = true
        defer { working = false }
        do {
            convertedDraft = try await api.convert(id: invoiceID)
            message = nil
            await reload()
        } catch {
            message = error.localizedDescription
        }
    }

    /// A refusal shows the server's message. On success the reload opens the draft.
    private func reverse(reload: @Sendable () async -> Void) async {
        working = true
        defer { working = false }
        do {
            _ = try await api.reverse(id: invoiceID)
            message = nil
            await reload()
        } catch {
            message = error.localizedDescription
        }
    }

    private func void(reload: @Sendable () async -> Void) async {
        working = true
        defer { working = false }
        do {
            try await api.void(id: invoiceID)
            message = nil
            await reload()
        } catch {
            message = error.localizedDescription
        }
    }

    private func remove(_ payment: Payment, reload: @Sendable () async -> Void) async {
        working = true
        defer { working = false }
        do {
            try await api.deletePayment(id: payment.id)
            message = nil
            await reload()
        } catch {
            message = error.localizedDescription
        }
    }
}

private struct PaymentRow: View {
    let payment: Payment
    let currency: String
    /// Nil when the row cannot be removed.
    let remove: (() -> Void)?

    private var details: [String] {
        var details = [ISODay.display(payment.paidOn)]
        if payment.groupId != nil { details.append("Customer payment") }
        if !payment.note.isEmpty { details.append(payment.note) }
        return details
    }

    var body: some View {
        HStack {
            LineRow(
                description: payment.kind.label,
                caption: details,
                amount: Money.format(payment.amount, currency)
            )
            if let remove {
                Button(role: .destructive, action: remove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove")
                .accessibilityIdentifier("payment.delete.\(payment.id)")
            }
        }
    }
}
