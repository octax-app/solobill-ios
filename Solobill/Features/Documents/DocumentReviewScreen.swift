import SwiftUI

/// Shows a saved draft with the server's totals, and issues it. A failed issue leaves the draft
/// as it is, so Issue can simply be tapped again.
///
/// With `onKeepDraft` this is the last step of the editor. Without it the draft was opened from a
/// list, so it also offers Edit and Delete.
struct DocumentReviewScreen: View {
    let invoiceID: Int
    let onIssued: (InvoiceFull) -> Void
    var onKeepDraft: (() -> Void)?

    @Environment(\.api) private var api

    private struct Review: Sendable {
        let invoice: InvoiceFull
        let customer: Customer
    }

    var body: some View {
        let api = api
        let id = invoiceID
        Loadable(id: id) {
            let invoice = try await api.invoice(id: id)
            return Review(invoice: invoice, customer: try await api.customer(id: invoice.customerId))
        } content: { review, reload in
            DocumentReviewContent(
                invoice: review.invoice,
                customer: review.customer,
                reload: reload,
                onIssued: onIssued,
                onKeepDraft: onKeepDraft
            )
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The list inside `DocumentReviewScreen`. `InvoiceDetailScreen` shows this for a manual draft.
struct DocumentReviewContent: View {
    let invoice: InvoiceFull
    let customer: Customer
    let reload: @Sendable () async -> Void
    let onIssued: (InvoiceFull) -> Void
    var onKeepDraft: (() -> Void)?

    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss
    @State private var isWorking = false
    @State private var isEditing = false
    @State private var confirmingDelete = false
    @State private var message: String?

    private var idPrefix: String { invoice.type.rawValue }
    private var word: String { invoice.type.word }

    var body: some View {
        List {
            Section {
                LabeledContent("Customer", value: customer.displayName)
                LabeledContent("Number", value: invoice.number ?? "Set when issued")
                if let issueDate = invoice.issueDate {
                    LabeledContent("Issue date", value: ISODay.display(issueDate))
                }
                if let dueOn = invoice.dueOn {
                    LabeledContent("Due on", value: ISODay.display(dueOn))
                }
                if let validUntil = invoice.validUntil {
                    LabeledContent("Valid until", value: ISODay.display(validUntil))
                }
            }
            Section("Lines") {
                ForEach(invoice.lines) { line in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(line.description)
                        Text("\(Money.amountInput(line.quantity)) × \(Money.format(line.unitPrice, invoice.currency))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("Totals") {
                LabeledContent("Subtotal", value: Money.format(invoice.subtotal, invoice.currency))
                    .accessibilityIdentifier("\(idPrefix).review.subtotal")
                if invoice.taxEnabled {
                    LabeledContent("Tax (\(Money.percentText(invoice.taxRate))%)", value: Money.format(invoice.tax, invoice.currency))
                        .accessibilityIdentifier("\(idPrefix).review.tax")
                }
                LabeledContent("Total", value: Money.format(invoice.total, invoice.currency))
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("\(idPrefix).review.total")
            }
            if !invoice.notes.isEmpty {
                Section("Notes") { Text(invoice.notes) }
            }
            Section {
                NavigationLink {
                    let api = api
                    let id = invoice.id
                    PDFScreen(title: "Preview", filename: "Draft") { try await api.invoicePDF(id: id) }
                } label: {
                    Label("Preview PDF", systemImage: "doc.richtext")
                }
                .accessibilityIdentifier("\(idPrefix).review.pdf")
            }
            issueSection
            if onKeepDraft == nil {
                manageSection
            }
        }
        .sheet(isPresented: $isEditing, onDismiss: { Task { await reload() } }) {
            DocumentEditorSheet(mode: .edit(invoice.type, id: invoice.id)) { issued in
                isEditing = false
                onIssued(issued)
            }
        }
        .alert("Delete this draft?", isPresented: $confirmingDelete) {
            Button("Delete draft", role: .destructive) {
                Task { await delete() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    private var issueSection: some View {
        Section {
            if let message {
                Text(message)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("\(idPrefix).review.error")
            }
            Button {
                Task { await issue() }
            } label: {
                if isWorking {
                    ProgressView()
                } else {
                    Text(message == nil ? "Issue \(word)" : "Try again")
                }
            }
            .disabled(isWorking)
            .accessibilityIdentifier("\(idPrefix).review.issue")
            if let onKeepDraft {
                Button("Keep as draft", action: onKeepDraft)
                    .disabled(isWorking)
                    .accessibilityIdentifier("\(idPrefix).review.keep")
            }
        } footer: {
            if message != nil {
                Text("The draft is saved. Nothing has been issued.")
            }
        }
    }

    private var manageSection: some View {
        Section {
            Button("Edit draft") { isEditing = true }
                .disabled(isWorking)
                .accessibilityIdentifier("\(idPrefix).review.edit")
            DuplicateDocumentButton(invoiceID: invoice.id, onIssued: onIssued)
            Button("Delete draft", role: .destructive) { confirmingDelete = true }
                .disabled(isWorking)
                .accessibilityIdentifier("\(idPrefix).review.delete")
        }
    }

    private func issue() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let issued = try await api.issue(id: invoice.id)
            message = nil
            onIssued(issued)
        } catch {
            message = error.localizedDescription
        }
    }

    private func delete() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await api.deleteDraft(id: invoice.id)
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }
}
