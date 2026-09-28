import CryptoKit
import Foundation
#if canImport(Security)
import Security
#endif

public protocol PairingPrivateKeyStore: Sendable {
    func loadOrCreatePrivateKeyData(for identity: ClientIdentity) throws -> Data
    func clearPrivateKey(for identity: ClientIdentity) throws
}

public struct EphemeralPairingPrivateKeyStore: PairingPrivateKeyStore {
    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var keys: [UUID: Data] = [:]

        func loadOrCreate(for identity: ClientIdentity) throws -> Data {
            lock.lock()
            defer { lock.unlock() }

            if let existing = keys[identity.identifier] {
                return existing
            }

            let keyData = P256.Signing.PrivateKey().rawRepresentation
            keys[identity.identifier] = keyData
            return keyData
        }

        func clear(for identity: ClientIdentity) {
            lock.lock()
            defer { lock.unlock() }
            keys.removeValue(forKey: identity.identifier)
        }
    }

    private let storage: Storage

    public init() {
        storage = Storage()
    }

    public func loadOrCreatePrivateKeyData(for identity: ClientIdentity) throws -> Data {
        try storage.loadOrCreate(for: identity)
    }

    public func clearPrivateKey(for identity: ClientIdentity) throws {
        storage.clear(for: identity)
    }
}

#if canImport(Security)
public struct KeychainPairingPrivateKeyStore: PairingPrivateKeyStore {
    public let service: String

    public init(service: String = "swift-moonlight.pairing-key") {
        self.service = service
    }

    public func loadOrCreatePrivateKeyData(for identity: ClientIdentity) throws -> Data {
        if let existing = try loadPrivateKeyData(for: identity) {
            return existing
        }

        let generated = P256.Signing.PrivateKey().rawRepresentation
        try savePrivateKeyData(generated, for: identity)
        return generated
    }

    public func clearPrivateKey(for identity: ClientIdentity) throws {
        let status = SecItemDelete(baseQuery(for: identity) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to clear pairing key from keychain: \(status)")
        }
    }

    private func loadPrivateKeyData(for identity: ClientIdentity) throws -> Data? {
        var query = baseQuery(for: identity)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to load pairing key from keychain: \(status)")
        }
        return data
    }

    private func savePrivateKeyData(_ data: Data, for identity: ClientIdentity) throws {
        var query = baseQuery(for: identity)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to save pairing key to keychain: \(status)")
        }
    }

    private func baseQuery(for identity: ClientIdentity) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "pairing-key-\(identity.identifier.uuidString.lowercased())"
        ]
    }
}
#endif

public struct P256PairingCryptoProvider: PairingCryptoProvider {
    public let keyStore: any PairingPrivateKeyStore

    public init(keyStore: any PairingPrivateKeyStore = EphemeralPairingPrivateKeyStore()) {
        self.keyStore = keyStore
    }

    public func identityMaterial(for identity: ClientIdentity) throws -> PairingIdentityMaterial {
        let privateKey = try loadPrivateKey(for: identity)
        let certificateBytes = privateKey.publicKey.x963Representation
        return PairingIdentityMaterial(
            clientCertificateHex: certificateBytes.hexString,
            certificateSignature: Data(SHA256.hash(data: certificateBytes))
        )
    }

    public func signClientSecret(_ clientSecret: Data, for identity: ClientIdentity) throws -> Data {
        let privateKey = try loadPrivateKey(for: identity)
        return try privateKey.signature(for: clientSecret).derRepresentation
    }

    public func serverCertificateSignature(certificateHex: String) throws -> Data {
        let certificateBytes = try Data(hexString: certificateHex)
        return Data(SHA256.hash(data: certificateBytes))
    }

    public func verifyServerSignature(secret: Data, signature: Data, certificateHex: String) throws -> Bool {
        let certificateBytes = try Data(hexString: certificateHex)
        let publicKey = try P256.Signing.PublicKey(x963Representation: certificateBytes)
        let ecdsaSignature = try P256.Signing.ECDSASignature(derRepresentation: signature)
        return publicKey.isValidSignature(ecdsaSignature, for: secret)
    }

    private func loadPrivateKey(for identity: ClientIdentity) throws -> P256.Signing.PrivateKey {
        let keyData = try keyStore.loadOrCreatePrivateKeyData(for: identity)
        return try P256.Signing.PrivateKey(rawRepresentation: keyData)
    }
}
