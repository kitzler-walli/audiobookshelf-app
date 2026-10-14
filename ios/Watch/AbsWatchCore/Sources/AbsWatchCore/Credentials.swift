import Foundation
import Security

/// The watch's own server session, obtained through the device-code flow.
public struct Credentials: Codable, Sendable, Equatable {
    public let serverAddress: URL
    public let serverName: String?
    public let username: String?
    public var accessToken: String
    public var refreshToken: String

    public init(serverAddress: URL, serverName: String?, username: String?, accessToken: String, refreshToken: String) {
        self.serverAddress = serverAddress
        self.serverName = serverName
        self.username = username
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }
}

public protocol CredentialStore: Sendable {
    func load() -> Credentials?
    func save(_ credentials: Credentials) throws
    func delete()
}

/// Stores credentials as a single Keychain item so access and refresh token are always replaced together.
/// Accessible after first unlock, so background downloads can refresh tokens while the watch is locked.
public struct KeychainCredentialStore: CredentialStore {
    private let service: String
    private let account = "credentials"

    public init(service: String = "kw.audiobookshelf.watch") {
        self.service = service
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func load() -> Credentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    public func save(_ credentials: Credentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(baseQuery.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Keychain write failed (\(status))"])
        }
    }

    public func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// Server response of /login, /auth/refresh and /auth/device-code/poll (when authorized).
struct LoginResponse: Decodable {
    struct User: Decodable {
        let username: String?
        let accessToken: String?
        let refreshToken: String?
    }
    let user: User
}
