import SwiftUI

/// Server URL + credentials sign-in. Quick Connect joins in Phase 1.
struct OnboardingView: View {
    @EnvironmentObject private var container: DependencyContainer
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isSigningIn = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Jellyfin Server") {
                    TextField("https://jellyfin.example.com", text: $serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Account") {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
                Button {
                    signIn()
                } label: {
                    if isSigningIn {
                        ProgressView()
                    } else {
                        Text("Sign In")
                    }
                }
                .disabled(serverURL.isEmpty || username.isEmpty || isSigningIn)
            }
            .navigationTitle("Jellyamp")
        }
    }

    private func signIn() {
        guard let url = URL(string: serverURL) else {
            errorMessage = "Invalid server URL"
            return
        }
        isSigningIn = true
        errorMessage = nil
        Task {
            do {
                try await container.signIn(serverURL: url, username: username, password: password)
            } catch {
                errorMessage = "Sign-in failed. Check the URL and credentials."
            }
            isSigningIn = false
        }
    }
}
