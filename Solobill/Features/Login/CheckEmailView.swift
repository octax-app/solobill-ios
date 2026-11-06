import SwiftUI

/// "Check your email", after registering or when signing in before confirming the address.
/// The link in the email opens the web app.
struct CheckEmailView: View {
    let email: String

    @Environment(\.api) private var api
    @State private var working = false
    @State private var sent = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Check your email", systemImage: "envelope.badge")
                .font(.headline)
            Text("We sent a link to \(email). Open it to confirm your address, then log in here.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let message {
                Text(message).font(.callout).foregroundStyle(.red)
            }
            Button(sent ? "Email sent again" : "Resend email") {
                Task { await resend() }
            }
            .disabled(working || sent)
            .accessibilityIdentifier("checkEmail.resend")
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("checkEmail")
    }

    private func resend() async {
        working = true
        defer { working = false }
        message = nil
        do {
            try await api.resendVerification(email: email.trimmingCharacters(in: .whitespaces))
            sent = true
        } catch {
            message = error.localizedDescription
        }
    }
}
