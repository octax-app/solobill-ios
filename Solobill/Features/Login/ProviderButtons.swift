import AuthenticationServices
import SwiftUI

/// Sign in with Apple and Continue with Google, each shown only when the server offers it.
/// `signIn` receives a function that runs the native flow and returns the credential.
struct ProviderButtons: View {
    let providers: AuthProviders
    let disabled: Bool
    let signIn: (@escaping @MainActor () async throws -> ProviderCredential) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var appleNonce: String?

    var body: some View {
        VStack(spacing: 12) {
            if providers.apple {
                SignInWithAppleButton(.signIn) { request in
                    appleNonce = AppleSignIn.prepare(request)
                } onCompletion: { result in
                    let nonce = appleNonce
                    appleNonce = nil
                    signIn {
                        switch result {
                        case .success(let authorization):
                            guard let nonce else { throw ProviderSignInError.badCallback }
                            return try AppleSignIn.credential(from: authorization, nonce: nonce)
                        case .failure(let error):
                            throw AppleSignIn.mapError(error)
                        }
                    }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 48)
                .clipShape(.capsule)
                .accessibilityIdentifier("login.apple")
            }
            if providers.googleClientID != nil {
                Button {
                    signIn { try await providers.signIn(with: .google) }
                } label: {
                    Text("Continue with Google")
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("login.google")
            }
        }
        .disabled(disabled)
    }
}
