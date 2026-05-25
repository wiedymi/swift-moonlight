import Foundation
#if canImport(Security)
import Security
#endif

public struct KeychainCredentialConfiguration: Sendable, Equatable {
    public var service: String
    public var accessGroup: String?

    public init(service: String = "dev.vivy.swift-moonlight", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }
}

public protocol KeychainItemStore: Sendable {
    func load(account: String, service: String, accessGroup: String?) throws -> Data?
    func save(_ data: Data, account: String, service: String, accessGroup: String?) throws
    func delete(account: String, service: String, accessGroup: String?) throws
}

#if canImport(Security)
public final class SecurityKeychainItemStore: @unchecked Sendable, KeychainItemStore {
    public init() {}

    public func load(account: String, service: String, accessGroup: String?) throws -> Data? {
        var query = baseQuery(account: account, service: service, accessGroup: accessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw keychainError(status, operation: "load")
        }
        guard let data = result as? Data else {
            throw MoonlightError(.unsupportedOperation, message: "Keychain item did not contain data")
        }
        return data
    }

    public func save(_ data: Data, account: String, service: String, accessGroup: String?) throws {
        var query = baseQuery(account: account, service: service, accessGroup: accessGroup)
        query[kSecValueData as String] = data

        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        guard addStatus == errSecDuplicateItem else {
            throw keychainError(addStatus, operation: "save")
        }

        let updateQuery = baseQuery(account: account, service: service, accessGroup: accessGroup)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)
        guard updateStatus == errSecSuccess else {
            throw keychainError(updateStatus, operation: "update")
        }
    }

    public func delete(account: String, service: String, accessGroup: String?) throws {
        let status = SecItemDelete(baseQuery(account: account, service: service, accessGroup: accessGroup) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status, operation: "delete")
        }
    }

    private func baseQuery(account: String, service: String, accessGroup: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func keychainError(_ status: OSStatus, operation: String) -> MoonlightError {
        let description = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return MoonlightError(.unsupportedOperation, message: "Keychain \(operation) failed: \(description)")
    }
}
#else
public final class SecurityKeychainItemStore: @unchecked Sendable, KeychainItemStore {
    public init() {}

    public func load(account: String, service: String, accessGroup: String?) throws -> Data? {
        _ = account
        _ = service
        _ = accessGroup
        throw unsupported()
    }

    public func save(_ data: Data, account: String, service: String, accessGroup: String?) throws {
        _ = data
        _ = account
        _ = service
        _ = accessGroup
        throw unsupported()
    }

    public func delete(account: String, service: String, accessGroup: String?) throws {
        _ = account
        _ = service
        _ = accessGroup
        throw unsupported()
    }

    private func unsupported() -> MoonlightError {
        MoonlightError(.unsupportedOperation, message: "Keychain storage requires Security.framework support")
    }
}
#endif

public actor KeychainIdentityStore: IdentityStore {
    private let itemStore: any KeychainItemStore
    private let configuration: KeychainCredentialConfiguration
    private let account: String
    private let defaultDisplayName: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        configuration: KeychainCredentialConfiguration = .init(),
        account: String = "client-identity",
        defaultDisplayName: String = "swift-moonlight"
    ) {
        self.init(
            itemStore: SecurityKeychainItemStore(),
            configuration: configuration,
            account: account,
            defaultDisplayName: defaultDisplayName
        )
    }

    init(
        itemStore: any KeychainItemStore,
        configuration: KeychainCredentialConfiguration,
        account: String = "client-identity",
        defaultDisplayName: String = "swift-moonlight"
    ) {
        self.itemStore = itemStore
        self.configuration = configuration
        self.account = account
        self.defaultDisplayName = defaultDisplayName
    }

    public func loadOrCreateIdentity() async throws -> ClientIdentity {
        if let data = try itemStore.load(
            account: account,
            service: configuration.service,
            accessGroup: configuration.accessGroup
        ) {
            return try decoder.decode(KeychainClientIdentityPayload.self, from: data).identity
        }

        let identity = ClientIdentity(displayName: defaultDisplayName)
        let data = try encoder.encode(KeychainClientIdentityPayload(identity: identity))
        try itemStore.save(
            data,
            account: account,
            service: configuration.service,
            accessGroup: configuration.accessGroup
        )
        return identity
    }

    public func clearIdentity() async throws {
        try itemStore.delete(
            account: account,
            service: configuration.service,
            accessGroup: configuration.accessGroup
        )
    }
}

private struct KeychainClientIdentityPayload: Codable {
    let identifier: UUID
    let displayName: String

    init(identity: ClientIdentity) {
        identifier = identity.identifier
        displayName = identity.displayName
    }

    var identity: ClientIdentity {
        ClientIdentity(identifier: identifier, displayName: displayName)
    }
}
