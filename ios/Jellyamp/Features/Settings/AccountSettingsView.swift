import SwiftUI
import JellyfinBackend

/// Settings → Account: which server and user this device is signed in to,
/// and sign-out. Self-contained; push it from a Settings row:
///
///     NavigationLink { AccountSettingsView() } label: { AccountSettingsRow() }
struct AccountSettingsView: View {
    @EnvironmentObject private var container: DependencyContainer
    @State private var isConfirmingSignOut = false

    var body: some View {
        Form {
            Section("Server") {
                LabeledContent("Name", value: container.account?.serverName ?? String(localized: "Jellyfin"))
                if let version = container.account?.serverVersion {
                    LabeledContent("Version", value: version)
                }
                if let session = container.session {
                    LabeledContent("Address") {
                        Text(session.serverURL.absoluteString)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                }
            }

            Section("Signed In As") {
                LabeledContent("User", value: container.account?.userName ?? String(localized: "Unknown"))
            }

            Section {
                Button("Sign Out", role: .destructive) {
                    isConfirmingSignOut = true
                }
            } footer: {
                Text("Signing out removes downloaded music and cached library data from this device. Your library on the server is not affected.")
            }

            Section {
                // App Review asks where accounts can be deleted; there is no
                // Jellyamp account to delete.
                Text("Jellyamp has no accounts of its own. Your account lives on your Jellyfin server and can only be changed or deleted there, by you or the server's administrator.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("About Your Account")
            }
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Sign out of this server?",
            isPresented: $isConfirmingSignOut,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                container.signOut()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Downloaded music will be removed from this device.")
        }
        .task {
            // Picks up a renamed/updated server and notices a revoked token
            // while the user is looking at this screen.
            await container.validateStoredSession()
        }
    }
}

/// Label for the Settings row that opens `AccountSettingsView`: user name
/// with the server name underneath.
struct AccountSettingsRow: View {
    @EnvironmentObject private var container: DependencyContainer

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.title)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(container.account?.userName ?? String(localized: "Account"))
                Text(container.account?.serverName ?? container.session?.serverURL.host ?? String(localized: "Jellyfin"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
