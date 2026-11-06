import SwiftUI

/// Sets a first password, for a Google or Apple user, or changes the current one.
struct PasswordSheet: View {
    let email: String
    let hasPassword: Bool
    let saved: @Sendable () async -> Void

    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var repeated = ""
    @State private var working = false
    @State private var message: String?

    private var problem: String? {
        if new.isEmpty { return nil }
        if let rule = PasswordRule.problem(new) { return rule }
        if !repeated.isEmpty, repeated != new { return "The passwords don't match." }
        return nil
    }

    private var canSave: Bool {
        (!hasPassword || !current.isEmpty) && PasswordRule.problem(new) == nil && new == repeated && !working
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Lets iOS save the new password under this account's email.
                    TextField("Email", text: .constant(email))
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .foregroundStyle(.secondary)
                    if hasPassword {
                        SecureField("Current password", text: $current)
                            .textContentType(.password)
                            .accessibilityIdentifier("password.current")
                    }
                }
                Section {
                    SecureField("New password", text: $new)
                        .textContentType(.newPassword)
                        .accessibilityIdentifier("password.new")
                    SecureField("Repeat new password", text: $repeated)
                        .textContentType(.newPassword)
                        .accessibilityIdentifier("password.repeat")
                } footer: {
                    Text(problem ?? "Use at least \(PasswordRule.minimum) characters.")
                        .foregroundStyle(problem == nil ? Color.secondary : Color.red)
                }
                if let message {
                    Section {
                        Text(message).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(hasPassword ? "Change password" : "Set a password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!canSave)
                        .accessibilityIdentifier("password.save")
                }
            }
        }
    }

    private func save() async {
        working = true
        defer { working = false }
        message = nil
        do {
            try await api.changePassword(current: hasPassword ? current : nil, new: new)
            await saved()
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }
}

/// Turns two-step login off. Asks for the password, or a current code when there is none.
struct TotpDisableSheet: View {
    let hasPassword: Bool
    let saved: @Sendable () async -> Void

    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss
    @State private var secret = ""
    @State private var working = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if hasPassword {
                        SecureField("Password", text: $secret)
                            .textContentType(.password)
                    } else {
                        TextField("6-digit code", text: $secret)
                            .textContentType(.oneTimeCode)
                            .keyboardType(.numberPad)
                    }
                } footer: {
                    Text(hasPassword ? "Enter your password to confirm." : "Enter a code from your authenticator app.")
                }
                if let message {
                    Section {
                        Text(message).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Turn off two-step login")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Turn off") { Task { await save() } }
                        .disabled(secret.isEmpty || working)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() async {
        working = true
        defer { working = false }
        message = nil
        do {
            _ = try await api.disableTotp(
                password: hasPassword ? secret : nil,
                code: hasPassword ? nil : secret.trimmingCharacters(in: .whitespaces)
            )
            await saved()
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }
}
