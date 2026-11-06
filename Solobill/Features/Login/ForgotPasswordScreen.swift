import SwiftUI

/// Sends a reset link. The link opens the web app, where the new password is set.
struct ForgotPasswordScreen: View {
    @Environment(\.api) private var api
    @State var email: String
    @State private var working = false
    @State private var sent = false
    @State private var message: String?

    var body: some View {
        Form {
            if sent {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Check your email", systemImage: "envelope.badge")
                            .font(.headline)
                        Text(
                            "If an account uses \(email), we sent it a link to choose a new password. The link opens in your browser and works for 1 hour."
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("forgot.sent")
                }
            } else {
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("forgot.email")
                } footer: {
                    Text("We'll email you a link to reset your password.")
                }
                if let message {
                    Section {
                        Text(message).foregroundStyle(.red)
                    }
                }
                Section {
                    Button {
                        Task { await send() }
                    } label: {
                        HStack {
                            Text("Send link")
                            if working {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(email.trimmingCharacters(in: .whitespaces).isEmpty || working)
                    .accessibilityIdentifier("forgot.submit")
                }
            }
        }
        .navigationTitle("Forgot password")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func send() async {
        working = true
        defer { working = false }
        message = nil
        do {
            email = email.trimmingCharacters(in: .whitespaces)
            try await api.forgotPassword(email: email)
            sent = true
        } catch {
            message = error.localizedDescription
        }
    }
}
