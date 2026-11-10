import SwiftUI
import JellyfinBackend

/// Two-step sign-in: (1) find the Jellyfin server, (2) sign in with a
/// password or Quick Connect. State and sequencing live in `OnboardingModel`.
struct OnboardingView: View {
    @EnvironmentObject private var container: DependencyContainer
    @StateObject private var model = OnboardingModel()
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case address
        case username
        case password
    }

    var body: some View {
        ZStack {
            OnboardingBackground()
            // A scroll view keeps everything reachable on small phones, with
            // large Dynamic Type sizes, and while the keyboard is up.
            ScrollView {
                VStack(spacing: 28) {
                    header
                    if let notice = container.signedOutNotice {
                        OnboardingMessage(text: notice, systemImage: "person.crop.circle.badge.exclamationmark", color: .yellow)
                    }
                    switch model.step {
                    case .server:
                        serverStep
                    case .signIn:
                        signInStep
                    }
                    footnote
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
                // Readable column on iPad instead of edge-to-edge fields.
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .tint(.white)
        .animation(.easeInOut(duration: 0.25), value: model.step)
        .task(id: model.step) {
            // Entering step 2 puts the cursor where typing continues.
            if model.step == .signIn {
                focus = .username
            }
        }
        .onAppear { model.probeRememberedAddress() }
        .onDisappear { model.tearDown() }
    }

    // MARK: - Header / footer

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 84, height: 84)
                .glassPanel(cornerRadius: 24)
                .accessibilityHidden(true)
            Text("Jellyamp")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
            Text("Your Jellyfin music library, everywhere.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .padding(.top, 12)
    }

    /// App Review requires a login-only app to explain what it connects to.
    private var footnote: some View {
        VStack(spacing: 6) {
            Text("Jellyamp plays music from your own Jellyfin server. Jellyfin is free, open-source media server software that you host yourself. Jellyamp does not provide or sell any content.")
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
            Link("Learn more at jellyfin.org", destination: URL(string: "https://jellyfin.org")!)
                .foregroundStyle(.white.opacity(0.85))
        }
        .font(.footnote)
        .padding(.top, 8)
    }

    // MARK: - Step 1: server

    private var addressBinding: Binding<String> {
        Binding(
            get: { model.address },
            set: { newValue in
                model.address = newValue
                model.addressDidChange()
            }
        )
    }

    private var serverStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect to your server")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
            Text("Enter the address of your Jellyfin server — the same one you open in a browser.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))

            TextField("jellyfin.example.com", text: addressBinding)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.continue)
                .focused($focus, equals: .address)
                .onSubmit { model.continueFromServer() }
                .onboardingField()
                .accessibilityLabel("Server address")

            serverStatus

            Button {
                model.continueFromServer()
            } label: {
                HStack(spacing: 10) {
                    if model.isCheckingServer {
                        ProgressView()
                            .tint(.black)
                    }
                    Text("Continue")
                }
            }
            .buttonStyle(OnboardingPrimaryButtonStyle())
            .disabled(!model.canContinue)

            Text("Examples: jellyfin.example.com, 192.168.1.5:8096 or https://example.com/jellyfin")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    @ViewBuilder
    private var serverStatus: some View {
        if let message = model.serverError {
            OnboardingMessage(text: message, systemImage: "exclamationmark.triangle.fill", color: .onboardingError)
        } else if let server = model.server {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("Jellyfin \(server.version)")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .accessibilityElement(children: .combine)
            insecureConnectionHint(for: server)
        } else if model.isCheckingServer {
            Text("Looking for a Jellyfin server…")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    // MARK: - Step 2: sign in

    private var methodBinding: Binding<OnboardingModel.Method> {
        Binding(
            get: { model.method },
            set: { newValue in model.select(method: newValue, container: container) }
        )
    }

    private var signInStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let server = model.server {
                serverSummary(server)
                insecureConnectionHint(for: server)
            }
            if model.quickConnectAvailable {
                Picker("Sign-in method", selection: methodBinding) {
                    Text("Password").tag(OnboardingModel.Method.password)
                    Text("Quick Connect").tag(OnboardingModel.Method.quickConnect)
                }
                .pickerStyle(.segmented)
            }
            switch model.method {
            case .password:
                passwordForm
            case .quickConnect:
                quickConnectCard
            }
        }
    }

    /// Plain HTTP is normal for a server on the home network and allowed on
    /// purpose. Against a public address it sends the password and the
    /// sign-in token readable across the internet — worth a note, but the
    /// user's call: nothing is blocked. `ServerHostPrivacy` (JellyfinBackend)
    /// decides which hosts count as private.
    @ViewBuilder
    private func insecureConnectionHint(for server: JellyfinServerInfo) -> some View {
        if ServerHostPrivacy.sendsCredentialsInClearText(to: server.url) {
            OnboardingMessage(
                text: String(localized: "This connection is not encrypted. Over the internet, others on the network could read your password. If your server offers it, use its https:// address instead."),
                systemImage: "lock.open.fill",
                color: .yellow
            )
        }
    }

    private func serverSummary(_ server: JellyfinServerInfo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.85))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Jellyfin \(server.version) · \(server.url.host ?? server.url.absoluteString)")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("Change") {
                model.backToServer()
                focus = .address
            }
            .font(.subheadline.weight(.semibold))
            .accessibilityLabel("Change server")
        }
        .padding(14)
        .glassPanel(cornerRadius: 16)
    }

    private var passwordForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Username", text: $model.username)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($focus, equals: .username)
                .onSubmit { focus = .password }
                .onboardingField()

            SecureField("Password", text: $model.password)
                .textContentType(.password)
                .submitLabel(.go)
                .focused($focus, equals: .password)
                .onSubmit { model.signInWithPassword(container: container) }
                .onboardingField()

            if let message = model.signInError {
                OnboardingMessage(text: message, systemImage: "exclamationmark.triangle.fill", color: .onboardingError)
            }

            Button {
                focus = nil
                model.signInWithPassword(container: container)
            } label: {
                HStack(spacing: 10) {
                    if model.isSigningIn {
                        ProgressView()
                            .tint(.black)
                    }
                    Text(model.isSigningIn ? "Signing In…" : "Sign In")
                }
            }
            .buttonStyle(OnboardingPrimaryButtonStyle())
            .disabled(!model.canSignIn)
        }
        .disabled(model.isSigningIn)
    }

    private var quickConnectCard: some View {
        VStack(spacing: 16) {
            switch model.quickConnect {
            case .idle, .starting:
                ProgressView()
                Text("Requesting a code…")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
            case .waiting(let code):
                Text("On a device where you're already signed in to Jellyfin, open Quick Connect from the user menu and enter this code:")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                Text(code)
                    .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                    .tracking(6)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .textSelection(.enabled)
                    .accessibilityLabel("Quick Connect code")
                    // Read digit by digit instead of as one large number.
                    .accessibilityValue(code.map { String($0) }.joined(separator: " "))
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Waiting for approval…")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .accessibilityElement(children: .combine)
                Button("Cancel") {
                    model.select(method: .password, container: container)
                }
                .font(.subheadline.weight(.semibold))
            case .finishing:
                ProgressView()
                Text("Signing in…")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
            case .failed(let message):
                OnboardingMessage(text: message, systemImage: "exclamationmark.triangle.fill", color: .onboardingError)
                Button("Get a New Code") {
                    model.startQuickConnect(container: container)
                }
                .buttonStyle(OnboardingPrimaryButtonStyle())
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .glassPanel(cornerRadius: 20)
    }
}

// MARK: - Building blocks

/// There is no artwork before sign-in, so the backdrop imitates the app's
/// blurred-artwork look with soft colour blooms on near-black.
private struct OnboardingBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.13, green: 0.08, blue: 0.28), Color(red: 0.02, green: 0.02, blue: 0.05)],
                startPoint: .top,
                endPoint: .bottom
            )
            Circle()
                .fill(Color.purple.opacity(0.35))
                .frame(width: 340, height: 340)
                .blur(radius: 90)
                .offset(x: -130, y: -280)
            Circle()
                .fill(Color.cyan.opacity(0.2))
                .frame(width: 300, height: 300)
                .blur(radius: 100)
                .offset(x: 150, y: -120)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Inline status line (error or notice): icon + wrapping text.
private struct OnboardingMessage: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote)
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension Color {
    /// Lighter than system red, which is too dim on the dark backdrop.
    static let onboardingError = Color(red: 1.0, green: 0.47, blue: 0.42)
}

private struct OnboardingFieldModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
    }
}

private extension View {
    func onboardingField() -> some View {
        modifier(OnboardingFieldModifier())
    }
}

/// White capsule, the app's primary control colour on dark backgrounds.
private struct OnboardingPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        OnboardingPrimaryButtonBody(configuration: configuration)
    }
}

/// Separate view because `isEnabled` is only reliable in a View's
/// environment, not in the ButtonStyle itself.
private struct OnboardingPrimaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 20)
            .background(Color.white, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
    }
}
