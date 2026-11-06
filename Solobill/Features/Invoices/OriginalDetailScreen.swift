import SwiftUI

/// One original invoice. Other features push this. Internal only.
struct OriginalDetailScreen: View {
    let originalID: Int

    @Environment(\.api) private var api
    @State private var markingPaid = false
    @State private var working = false
    @State private var message: String?

    private struct Details: Sendable {
        let original: OriginalFull
        let providerName: String?
    }

    var body: some View {
        Loadable(id: originalID) { [api, originalID] in
            async let original = api.original(id: originalID)
            async let providers = api.providers()
            let loaded = try await original
            let name = try await providers.first { $0.id == loaded.providerId }?.name
            return Details(original: loaded, providerName: name)
        } content: { details, reload in
            content(details, reload: reload)
                .refreshable { await reload() }
                .navigationTitle(title(of: details.original))
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func title(of original: OriginalFull) -> String {
        original.number.isEmpty ? "Original invoice" : original.number
    }

    private func content(_ details: Details, reload: @escaping @Sendable () async -> Void) -> some View {
        let original = details.original
        return List {
            Section {
                if let name = details.providerName { LabeledContent("Provider", value: name) }
                LabeledContent("Status") {
                    StatusText(paidOn: original.paidOn, dueOn: original.dueOn)
                        .accessibilityIdentifier("original.status")
                }
                LabeledContent("Issued", value: ISODay.display(original.issuedOn))
                if let dueOn = original.dueOn { LabeledContent("Due", value: ISODay.display(dueOn)) }
                if let paidOn = original.paidOn { LabeledContent("Paid on", value: ISODay.display(paidOn)) }
            }

            Section("Lines") {
                ForEach(original.lines) { line in
                    LineRow(
                        description: line.description,
                        caption: ["\(Money.amountInput(line.quantity)) × \(Money.format(line.unitPrice, original.currency))"],
                        amount: Money.format(line.total, original.currency)
                    )
                }
            }

            Section {
                total("Subtotal", original.subtotal, original.currency)
                total("Tax", original.tax, original.currency)
                total("Total", original.total, original.currency).bold()
            }

            if !original.notes.isEmpty {
                Section("Notes") { Text(original.notes) }
            }

            Section {
                if let key = original.pdfFile {
                    NavigationLink {
                        PDFScreen(title: title(of: original), filename: title(of: original)) { [api] in
                            try await api.file(key: key)
                        }
                    } label: {
                        Label("View PDF", systemImage: "doc.richtext")
                    }
                    .accessibilityIdentifier("original.pdf")
                }
                if original.paidOn == nil {
                    Button("Mark as paid") { markingPaid = true }
                        .accessibilityIdentifier("original.markPaid")
                } else {
                    Button("Undo paid") {
                        Task { await undoPaid(reload: reload) }
                    }
                    .disabled(working)
                    .accessibilityIdentifier("original.undoPaid")
                }
            }

            if let message {
                Section { Text(message).foregroundStyle(.red) }
            }
        }
        .sheet(isPresented: $markingPaid) {
            MarkPaidSheet(
                title: title(of: original),
                amount: Money.format(original.total, original.currency)
            ) { day in
                try await api.markPaid(originalId: original.id, on: day)
                await reload()
            }
        }
    }

    private func total(_ label: String, _ amount: Int, _ currency: String) -> some View {
        LabeledContent(label, value: Money.format(amount, currency))
            .monospacedDigit()
            .accessibilityIdentifier("original.\(label.lowercased())")
    }

    private func undoPaid(reload: @Sendable () async -> Void) async {
        working = true
        defer { working = false }
        do {
            try await api.markUnpaid(originalId: originalID)
            message = nil
            await reload()
        } catch {
            message = error.localizedDescription
        }
    }
}
