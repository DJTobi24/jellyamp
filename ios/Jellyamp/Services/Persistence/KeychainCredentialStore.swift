import Foundation
import Security
import JellyfinBackend

/// Server credentials and tokens live in the Keychain, never UserDefaults.
final class KeychainCredentialStore {
    private let service = "dev.djtobi.jellyamp"

    func save(session: JellyfinSession) {
        guard let data = try? JSONEncoder().encode(StoredSession(from: session)) else { return }
        store(key: "session", data: data)
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
