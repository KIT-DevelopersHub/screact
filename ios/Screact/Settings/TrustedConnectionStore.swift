import Foundation
import Security

/// Port of Android TrustedConnectionStore. Host/port live in UserDefaults; the resume token is
/// kept in the iOS Keychain (kSecClassGenericPassword) — the platform-native equivalent of the
/// Android Keystore-encrypted SharedPreferences entry.
struct TrustedConnection {
    let host: String
    let port: Int
    let resumeToken: String
}

protocol TrustedConnectionValues {
    func string(forKey key: String) -> String?
    func int(forKey key: String, default defaultValue: Int) -> Int
    func put(_ values: [String: Any])
    func remove(_ keys: Set<String>)
}

final class UserDefaultsTrustedConnectionValues: TrustedConnectionValues {
    private let defaults: UserDefaults
    init(_ defaults: UserDefaults) { self.defaults = defaults }

    func string(forKey key: String) -> String? { defaults.string(forKey: key) }
    func int(forKey key: String, default defaultValue: Int) -> Int {
        defaults.object(forKey: key) == nil ? defaultValue : defaults.integer(forKey: key)
    }
    func put(_ values: [String: Any]) {
        for (key, value) in values { defaults.set(value, forKey: key) }
    }
    func remove(_ keys: Set<String>) {
        for key in keys { defaults.removeObject(forKey: key) }
    }
}

/// Secure storage for the resume token. Android used AES/GCM via the keystore; on iOS the
/// Keychain provides equivalent at-rest protection, so no separate cipher layer is needed.
protocol ResumeTokenProtector {
    func store(_ token: String) -> Bool
    func load() -> String?
    func clear()
}

final class KeychainResumeTokenProtector: ResumeTokenProtector {
    private let account = "yubiboard_resume_token_v1"
    private let service = "com.nxtend.team35.yubiboard"

    func store(_ token: String) -> Bool {
        guard let data = token.data(using: .utf8) else { return false }
        clear()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

final class TrustedConnectionStore {
    static let keyHost = "trusted_host"
    static let keyPort = "trusted_port"

    private let values: TrustedConnectionValues
    private let protector: ResumeTokenProtector

    init(values: TrustedConnectionValues, protector: ResumeTokenProtector) {
        self.values = values
        self.protector = protector
    }

    func load() -> TrustedConnection? {
        guard let host = values.string(forKey: Self.keyHost),
              let token = protector.load() else { return nil }
        let port = values.int(forKey: Self.keyPort, default: -1)
        let connection = TrustedConnection(host: host, port: port, resumeToken: token)
        if ConnectionConfig(host: host, port: port, resumeToken: token).validate() == nil {
            return connection
        }
        clear()
        return nil
    }

    @discardableResult
    func save(host: String, port: Int, resumeToken: String) -> Bool {
        guard ConnectionConfig(host: host, port: port, resumeToken: resumeToken).validate() == nil else {
            return false
        }
        values.put([Self.keyHost: host, Self.keyPort: port])
        return protector.store(resumeToken)
    }

    func clear() {
        values.remove([Self.keyHost, Self.keyPort])
        protector.clear()
    }
}

final class TrustedConnectionCoordinator {
    private let store: TrustedConnectionStore
    private let connect: (ConnectionConfig, Bool) -> Void

    init(store: TrustedConnectionStore, connect: @escaping (ConnectionConfig, Bool) -> Void) {
        self.store = store
        self.connect = connect
    }

    @discardableResult
    func autoConnect() -> Bool {
        guard let trusted = store.load() else { return false }
        connect(ConnectionConfig(host: trusted.host, port: trusted.port, resumeToken: trusted.resumeToken), true)
        return true
    }

    @discardableResult
    func save(host: String, port: Int, resumeToken: String) -> Bool {
        store.save(host: host, port: port, resumeToken: resumeToken)
    }

    func forget() { store.clear() }

    func savedConnection() -> TrustedConnection? { store.load() }
}
