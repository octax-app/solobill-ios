import SwiftUI

/// Copies a document into a new draft and opens it in the editor. A refusal shows the server's
/// message, which happens when another document holds the subscription's next period.
struct DuplicateDocumentButton: View {
    let invoiceID: Int
    let onIssued: (InvoiceFull) -> Void

    @Environment(\.api) private var api
    @State private var copy: InvoiceFull?
    @State private var working = false
    @State private var message: String?

    var body: some View {
        Button("Duplicate") {
            Task { await duplicate() }
        }
        .disabled(working)
        .accessibilityIdentifier("invoice.duplicate")
        .sheet(item: $copy) { copy in
            DocumentEditorSheet(mode: .edit(copy.type, id: copy.id)) { issued in
                self.copy = nil
                onIssued(issued)
            }
        }
        if let message {
            Text(message)
                .foregroundStyle(.red)
                .accessibilityIdentifier("invoice.duplicate.error")
        }
    }

    private func duplicate() async {
        working = true
        defer { working = false }
        do {
            copy = try await api.duplicate(id: invoiceID)
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }
}
