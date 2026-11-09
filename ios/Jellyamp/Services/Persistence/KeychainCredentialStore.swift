import Foundation
import Security
import JellyfinBackend

/// Server credentials and tokens live in the Keychain, never UserDefaults.
final class KeychainCredentialStore {
    private let service = "dev.djtobi.jellyamp"

    /// Stores the session together with what Settings → Account displays
    /// (server name/version, user name) so that screen works offline too.
    func save(session: JellyfinSession, account: JellyfinAccount? = nil) {
        var stored = StoredSession(from: session)
        stored.serverName = account?.serverName
        stored.serverVersion = account?.serverVersion
        stored.userName = account?.userName
        guard let data = try? JSONEncoder().encode(stored) else { return }
        store(key: "session", data: data)
    }

    /// Display info saved alongside the session. Sessions stored by versions
    /// that predate these fields decode to an account with all fields nil.
    func loadAccount() -> JellyfinAccount? {
        guard let data = load(key: "session") else { return nil }
        return try? JSONDecoder().decode(JellyfinAccount.self, from: data)
    }

    func loadSession() -> JellyfinSession? {
        guard let data = load(key: "session"),
              let stored = try? JSONDecoder().decode(StoredSession.self, from: data) else {
            return nil
        }
        return stored.session
    }

    func saveSonicAPIKey(_ key: String) {
        store(key: "sonicApiKey", data: Data(key.utf8))
    }

    func loadSonicAPIKey() -> String? {
        load(key: "sonicApiKey").map { String(decoding: $0, as: UTF8.self) }
    }

    func clear() {
        delete(key: "session")
        delete(key: "sonicApiKey")
    }

    // MARK: - Keychain plumbing

    private func store(key: String, data: Data) {
        delete(key: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private func load(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private struct StoredSession: Codable {
    var serverURL: URL
    var deviceID: String
    var accessToken: String?
    var userID: String?
    // Added after the first release: optional, and named exactly like
    // `JellyfinAccount`'s properties, which is decoded from the same blob.
    var serverName: String?
    var serverVersion: String?
    var userName: String?

    init(from session: JellyfinSession) {
        serverURL = session.serverURL
        deviceID = session.deviceID
        accessToken = session.accessToken
        userID = session.userID
    }

    var session: JellyfinSession {
        JellyfinSession(serverURL: serverURL, deviceID: deviceID, accessToken: accessToken, userID: userID)
    }
}

// MARK: - Scrobbling credentials

/// ListenBrainz user token and Last.fm session key. Kept apart from
/// `clear()` because they belong to the scrobbling accounts, not the
/// Jellyfin login; `ScrobbleService` removes them on disconnect / sign-out.
extension KeychainCredentialStore {
    func saveListenBrainzToken(_ token: String) {
        store(key: "listenBrainzToken", data: Data(token.utf8))
    }

    func loadListenBrainzToken() -> String? {
        load(key: "listenBrainzToken").map { String(decoding: $0, as: UTF8.self) }
    }

    func deleteListenBrainzToken() {
        delete(key: "listenBrainzToken")
    }

    func saveLastFMSessionKey(_ key: String) {
        store(key: "lastFMSessionKey", data: Data(key.utf8))
    }

    func loadLastFMSessionKey() -> String? {
        load(key: "lastFMSessionKey").map { String(decoding: $0, as: UTF8.self) }
    }

    func deleteLastFMSessionKey() {
        delete(key: "lastFMSessionKey")
    }

    func clearScrobblingCredentials() {
        delete(key: "listenBrainzToken")
        delete(key: "lastFMSessionKey")
    }
}
