import Combine
import Foundation
import UIKit
import JellyfinBackend

/// State machine behind the two-step onboarding: find the server, then sign
/// in with a password or Quick Connect. All network logic lives in
/// `JellyfinBackend`; this only sequences it for the view.
@MainActor
final class OnboardingModel: ObservableObject {
    enum Step {
        case server
        case signIn
    }

    enum Method: Hashable {
        case password
        case quickConnect
    }

    enum QuickConnectPhase: Equatable {
        case idle
        /// Asking the server for a code.
        case starting
        /// Showing the code, polling for approval.
        case waiting(code: String)
        /// Approved; exchanging the secret for a token.
        case finishing
        case failed(message: String)
    }

    @Published var step: Step = .server

    // Step 1
    @Published var address: String
    @Published private(set) var server: JellyfinServerInfo?
    @Published private(set) var isCheckingServer = false
    @Published private(set) var serverError: String?

    // Step 2
    @Published private(set) var method: Method = .password
    @Published private(set) var quickConnectAvailable = false
    @Published var username = ""
    @Published var password = ""
    @Published private(set) var isSigningIn = false
    @Published private(set) var signInError: String?
    @Published private(set) var quickConnect: QuickConnectPhase = .idle

    private static let lastAddressKey = "jellyamp.lastServerAddress"

    private let discovery = JellyfinServerDiscovery()
    private let authenticator = JellyfinAuthenticator()
    /// The address `server` was discovered for, to know when it went stale.
    private var serverAddress: String?
    private var probeTask: Task<Void, Never>?
    private var probeGeneration = 0
    private var quickConnectTask: Task<Void, Never>?

    init() {
        // Not a secret, so UserDefaults is fine; saves retyping after a
        // sign-out or an expired session.
        address = UserDefaults.standard.string(forKey: Self.lastAddressKey) ?? ""
    }

    var canContinue: Bool {
        !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canSignIn: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSigningIn
    }

    // MARK: - Step 1: server

    /// Live validation: once typing pauses, probe quietly. Only success is
    /// shown — a half-typed address failing is not worth an error message;
    /// errors appear when the user explicitly continues.
    func addressDidChange() {
        guard address != serverAddress else { return }
        probeTask?.cancel()
        probeGeneration += 1
        server = nil
        serverAddress = nil
        serverError = nil
        isCheckingServer = false
        guard canContinue else { return }
        let generation = probeGeneration
        let typed = address
        probeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            await self?.probe(typed, generation: generation, reportErrors: false)
        }
    }

    /// Checks an address remembered from last time as soon as the screen
    /// appears, so a returning user sees their server straight away.
    func probeRememberedAddress() {
        guard server == nil, canContinue, probeTask == nil else { return }
        probeGeneration += 1
        let generation = probeGeneration
        let typed = address
        probeTask = Task { [weak self] in
            await self?.probe(typed, generation: generation, reportErrors: false)
        }
    }

    /// The Continue button / keyboard submit.
    func continueFromServer() {
        guard canContinue else { return }
        if server != nil, serverAddress == address {
            enterSignInStep()
            return
        }
        probeTask?.cancel()
        probeGeneration += 1
        let generation = probeGeneration
        let typed = address
        probeTask = Task { [weak self] in
            guard let self else { return }
            await self.probe(typed, generation: generation, reportErrors: true)
            if generation == self.probeGeneration, self.server != nil {
                self.enterSignInStep()
            }
        }
    }

    private func probe(_ typed: String, generation: Int, reportErrors: Bool) async {
        isCheckingServer = true
        serverError = nil
        do {
            let found = try await discovery.discover(address: typed)
            guard generation == probeGeneration else { return }
            server = found
            serverAddress = typed
            isCheckingServer = false
        } catch {
            // A newer probe owns the state now.
            guard generation == probeGeneration else { return }
            isCheckingServer = false
            if reportErrors, let message = SignInErrorMessage.text(for: error) {
                serverError = message
                announce(message)
            }
        }
    }

    private func enterSignInStep() {
        guard let server else { return }
        UserDefaults.standard.set(server.url.absoluteString, forKey: Self.lastAddressKey)
        signInError = nil
        method = .password
        quickConnect = .idle
        quickConnectAvailable = false
        step = .signIn
        let session = sessionTemplate(for: server)
        Task { [weak self] in
            guard let self else { return }
            let enabled = await self.authenticator.isQuickConnectEnabled(session: session)
            // Ignore the answer if the user already went back to step 1.
            if self.step == .signIn, self.server == server {
                self.quickConnectAvailable = enabled
            }
        }
    }

    /// "Change server" on step 2.
    func backToServer() {
        cancelQuickConnect()
        password = ""
        signInError = nil
        method = .password
        step = .server
    }

    // MARK: - Step 2: password

    func signInWithPassword(container: DependencyContainer) {
        guard let server, canSignIn else { return }
        isSigningIn = true
        signInError = nil
        let session = container.makeSignInSession(server: server)
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = password
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.authenticator.signIn(session: session, username: name, password: secret)
                // RootView swaps onboarding out once the container is signed in.
                await container.completeSignIn(result, server: server)
            } catch {
                if let message = SignInErrorMessage.text(for: error) {
                    self.signInError = message
                    self.announce(message)
                }
                if let connectionError = error as? JellyfinConnectionError, connectionError == .wrongCredentials {
                    self.password = ""
                }
            }
            self.isSigningIn = false
        }
    }

    // MARK: - Step 2: Quick Connect

    func select(method newMethod: Method, container: DependencyContainer) {
        guard newMethod != method else { return }
        method = newMethod
        signInError = nil
        switch newMethod {
        case .password:
            cancelQuickConnect()
        case .quickConnect:
            startQuickConnect(container: container)
        }
    }

    /// Requests a code and polls until it is approved, times out, or the
    /// user cancels. Also the "Get a new code" action.
    func startQuickConnect(container: DependencyContainer) {
        guard let server else { return }
        quickConnectTask?.cancel()
        quickConnect = .starting
        let session = container.makeSignInSession(server: server)
        quickConnectTask = Task { [weak self] in
            guard let self else { return }
            do {
                let state = try await self.authenticator.initiateQuickConnect(session: session)
                try Task.checkCancellation()
                self.quickConnect = .waiting(code: state.code)
                try await self.authenticator.waitForQuickConnectApproval(session: session, state: state)
                try Task.checkCancellation()
                self.quickConnect = .finishing
                let result = try await self.authenticator.signInWithQuickConnect(session: session, state: state)
                try Task.checkCancellation()
                await container.completeSignIn(result, server: server)
            } catch {
                // Cancelled: whoever cancelled already reset the state.
                guard !Task.isCancelled, let message = SignInErrorMessage.text(for: error) else { return }
                if let connectionError = error as? JellyfinConnectionError, connectionError == .quickConnectDisabled {
                    // The admin switched it off after we asked; hide the option.
                    self.quickConnectAvailable = false
                    self.method = .password
                    self.quickConnect = .idle
                    self.signInError = message
                } else {
                    self.quickConnect = .failed(message: message)
                }
                self.announce(message)
            }
        }
    }

    func cancelQuickConnect() {
        quickConnectTask?.cancel()
        quickConnectTask = nil
        quickConnect = .idle
    }

    /// Stops all background work when the screen goes away.
    func tearDown() {
        probeTask?.cancel()
        quickConnectTask?.cancel()
    }

    // MARK: - Helpers

    /// Only used for the unauthenticated "is Quick Connect enabled" check,
    /// which needs no stable device identity.
    private func sessionTemplate(for server: JellyfinServerInfo) -> JellyfinSession {
        JellyfinSession(serverURL: server.url, deviceID: "jellyamp-onboarding")
    }

    /// Errors appear inline, which VoiceOver would not notice by itself.
    private func announce(_ message: String) {
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}
