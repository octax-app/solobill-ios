import SwiftUI

/// Asks for the paid date, then runs `confirm` with it as "YYYY-MM-DD". Used for customer
/// invoices and original invoices. Present it with `.sheet`.
struct MarkPaidSheet: View {
    let title: String
    let amount: String
    let confirm: @MainActor (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date = Date.now
    @State private var working = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Invoice", value: title)
                    LabeledContent("Amount", value: amount)
                    DatePicker("Paid on", selection: $date, in: ...Date.now, displayedComponents: .date)
                }
                if let message {
                    Section {
                        Text(message).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Mark as paid")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(working)
                    .accessibilityIdentifier("markPaid.save")
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() async {
        working = true
        defer { working = false }
        do {
            try await confirm(ISODay.string(from: date))
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }
}
