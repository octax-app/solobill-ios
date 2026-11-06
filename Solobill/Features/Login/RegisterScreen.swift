import SwiftUI

/// Creates an account and its workspace. The server always answers the same, whether or not the
/// email is taken, and the email says which it was.
struct RegisterScreen: View {
    @Environment(\.api) private var api
    @State private var name = ""
    @State private var workspaceName = ""
    @State private var email = ""
    @State private var password = ""
    @State private var working = false
    @State private var registered = false
    @State private var message: String?

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespaces) }

    private var canSubmit: Bool {
        !workspaceName.trimmingCharacters(in: .whitespaces).isEmpty && !trimmedEmail.isEmpty
            && PasswordRule.problem(password) == nil && !working
    }

    var body: some View {
        Form {
            if registered {
                Section {
                    CheckEmailView(email: trimmedEmail)
                }
            } else {
                Section {
                    TextField("Your name (optional)", text: $name)
                        .textContentType(.name)
                        .accessibilityIdentifier("register.name")
                    TextField("Business name", text: $workspaceName)
                        .textContentType(.organizationName)
                        .accessibilityIdentifier("register.workspace")
                }
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("register.email")
                    SecureField("Password", text: $password)
                        .textContentType(.newPassword)
                        .accessibilityIdentifier("register.password")
                } footer: {
                    Text("Use at least \(PasswordRule.minimum) characters.")
                }
                if let message {
                    Section {
                        Text(message)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("register.error")
                    }
                }
                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Text("Create account")
                            if working {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("register.submit")
                }
            }
        }
        .navigationTitle("Create account")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func submit() async {
        working = true
        defer { working = false }
        message = nil
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        do {
            try await api.register(
                RegisterInput(
                    email: trimmedEmail,
                    password: password,
                    name: trimmedName.isEmpty ? nil : trimmedName,
                    workspaceName: workspaceName.trimmingCharacters(in: .whitespaces)
                )
            )
            registered = true
        } catch {
            message = error.localizedDescription
        }
    }
}
