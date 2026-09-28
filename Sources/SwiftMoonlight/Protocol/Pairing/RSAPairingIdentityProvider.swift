import Foundation
#if canImport(Security)
import Security
#endif

public protocol RSAPairingIdentityStore: Sendable {
    func loadOrCreateIdentityMaterial(for identity: ClientIdentity) throws -> RSAPairingIdentityMaterial
    func clearIdentityMaterial(for identity: ClientIdentity) throws
}

public struct RSAPairingIdentityMaterial: Codable, Sendable, Equatable {
    public var privateKeyData: Data
    public var certificatePEM: String

    public init(privateKeyData: Data, certificatePEM: String) {
        self.privateKeyData = privateKeyData
        self.certificatePEM = certificatePEM
    }
}

public final class FileRSAPairingIdentityStore: @unchecked Sendable, RSAPairingIdentityStore {
    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func loadOrCreateIdentityMaterial(for identity: ClientIdentity) throws -> RSAPairingIdentityMaterial {
        lock.lock()
        defer { lock.unlock() }

        if FileManager.default.fileExists(atPath: fileURL.fileSystemPath) {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(RSAPairingIdentityMaterial.self, from: data)
        }

        let material = try RSAPairingIdentityGenerator().generate(commonName: "NVIDIA GameStream Client", serialSeed: identity.identifier)
        let data = try JSONEncoder().encode(material)
        try writeAtomically(data, to: fileURL)
        return material
    }

    public func clearIdentityMaterial(for identity: ClientIdentity) throws {
        _ = identity
        lock.lock()
        defer { lock.unlock() }

        guard FileManager.default.fileExists(atPath: fileURL.fileSystemPath) else {
            return
        }
        try FileManager.default.removeItem(at: fileURL)
    }
}

public final class EphemeralRSAPairingIdentityStore: @unchecked Sendable, RSAPairingIdentityStore {
    private let lock = NSLock()
    private var cached: [UUID: RSAPairingIdentityMaterial] = [:]

    public init() {}

    public func loadOrCreateIdentityMaterial(for identity: ClientIdentity) throws -> RSAPairingIdentityMaterial {
        lock.lock()
        defer { lock.unlock() }

        if let existing = cached[identity.identifier] {
            return existing
        }

        let material = try RSAPairingIdentityGenerator().generate(commonName: "NVIDIA GameStream Client", serialSeed: identity.identifier)
        cached[identity.identifier] = material
        return material
    }

    public func clearIdentityMaterial(for identity: ClientIdentity) throws {
        lock.lock()
        defer { lock.unlock() }
        cached.removeValue(forKey: identity.identifier)
    }
}

public final class KeychainRSAPairingIdentityStore: @unchecked Sendable, RSAPairingIdentityStore {
    private let itemStore: any KeychainItemStore
    private let configuration: KeychainCredentialConfiguration
    private let accountPrefix: String
    private let lock = NSLock()

    public init(
        configuration: KeychainCredentialConfiguration = .init(),
        accountPrefix: String = "rsa-pairing-identity"
    ) {
        self.itemStore = SecurityKeychainItemStore()
        self.configuration = configuration
        self.accountPrefix = accountPrefix
    }

    init(
        itemStore: any KeychainItemStore,
        configuration: KeychainCredentialConfiguration,
        accountPrefix: String = "rsa-pairing-identity"
    ) {
        self.itemStore = itemStore
        self.configuration = configuration
        self.accountPrefix = accountPrefix
    }

    public func loadOrCreateIdentityMaterial(for identity: ClientIdentity) throws -> RSAPairingIdentityMaterial {
        lock.lock()
        defer { lock.unlock() }

        let account = account(for: identity)
        if let data = try itemStore.load(
            account: account,
            service: configuration.service,
            accessGroup: configuration.accessGroup
        ) {
            return try JSONDecoder().decode(RSAPairingIdentityMaterial.self, from: data)
        }

        let material = try RSAPairingIdentityGenerator().generate(commonName: "NVIDIA GameStream Client", serialSeed: identity.identifier)
        let data = try JSONEncoder().encode(material)
        try itemStore.save(
            data,
            account: account,
            service: configuration.service,
            accessGroup: configuration.accessGroup
        )
        return material
    }

    public func clearIdentityMaterial(for identity: ClientIdentity) throws {
        lock.lock()
        defer { lock.unlock() }

        try itemStore.delete(
            account: account(for: identity),
            service: configuration.service,
            accessGroup: configuration.accessGroup
        )
    }

    private func account(for identity: ClientIdentity) -> String {
        "\(accountPrefix)-\(identity.identifier.uuidString)"
    }
}

public struct GeneratedRSAPairingCryptoProvider: PairingCryptoProvider {
    public let identityStore: any RSAPairingIdentityStore

    public init(identityStore: any RSAPairingIdentityStore = EphemeralRSAPairingIdentityStore()) {
        self.identityStore = identityStore
    }

    public func identityMaterial(for identity: ClientIdentity) throws -> PairingIdentityMaterial {
        let stored = try identityStore.loadOrCreateIdentityMaterial(for: identity)
        let certificateData = Data(stored.certificatePEM.utf8)
        return PairingIdentityMaterial(
            clientCertificateHex: certificateData.hexString,
            certificateSignature: try X509CertificateParser.signatureBytes(fromPEMOrDER: certificateData)
        )
    }

    public func signClientSecret(_ clientSecret: Data, for identity: ClientIdentity) throws -> Data {
        let stored = try identityStore.loadOrCreateIdentityMaterial(for: identity)
        #if canImport(Security)
        let privateKey = try RSAKeychainlessCodec.makePrivateKey(from: stored.privateKeyData)
        return try RSAKeychainlessCodec.sign(clientSecret, with: privateKey)
        #else
        throw MoonlightError(.unsupportedOperation, message: "RSA pairing requires Security.framework support")
        #endif
    }

    public func serverCertificateSignature(certificateHex: String) throws -> Data {
        try X509CertificateParser.signatureBytes(fromPEMOrDER: try Data(hexString: certificateHex))
    }

    public func verifyServerSignature(secret: Data, signature: Data, certificateHex: String) throws -> Bool {
        #if canImport(Security)
        let certificateData = try Data(hexString: certificateHex)
        let publicKey = try RSAKeychainlessCodec.makeCertificatePublicKey(from: certificateData)
        return try RSAKeychainlessCodec.verify(signature, for: secret, with: publicKey)
        #else
        throw MoonlightError(.unsupportedOperation, message: "RSA pairing requires Security.framework support")
        #endif
    }
}

#if canImport(Security)
private enum RSAKeychainlessCodec {
    static func makePrivateKey(from externalRepresentation: Data) throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 2048,
        ]

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(externalRepresentation as CFData, attributes as CFDictionary, &error) else {
            let message = (error?.takeRetainedValue() as Error?)?.localizedDescription ?? "unknown error"
            throw MoonlightError(.unsupportedOperation, message: "RSA private key creation from data failed: \(message)")
        }
        return key
    }

    static func makeCertificatePublicKey(from pemOrDER: Data) throws -> SecKey {
        let der = try PEMCodec.decodeCertificate(pemOrDER)
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to parse X.509 certificate")
        }
        guard let key = SecCertificateCopyKey(certificate) else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to extract X.509 public key")
        }
        return key
    }

    static func sign(_ data: Data, with privateKey: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            data as CFData,
            &error
        ) as Data? else {
            let message = (error?.takeRetainedValue() as Error?)?.localizedDescription ?? "unknown error"
            throw MoonlightError(.unsupportedOperation, message: "Failed to sign RSA pairing payload: \(message)")
        }
        return signature
    }

    static func verify(_ signature: Data, for data: Data, with publicKey: SecKey) throws -> Bool {
        var error: Unmanaged<CFError>?
        let valid = SecKeyVerifySignature(
            publicKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            data as CFData,
            signature as CFData,
            &error
        )
        if let error {
            let message = (error.takeRetainedValue() as Error).localizedDescription
            throw MoonlightError(.unsupportedOperation, message: "Failed to verify RSA pairing signature: \(message)")
        }
        return valid
    }
}

private struct RSAPairingIdentityGenerator {
    func generate(commonName: String, serialSeed: UUID) throws -> RSAPairingIdentityMaterial {
        let privateKey = try generatePrivateKey()
        let privateKeyData = try export(privateKey: privateKey)
        let publicKey = try publicKey(from: privateKey)
        let publicKeyData = try export(publicKey: publicKey)
        let certificateDER = try SelfSignedX509Builder().makeCertificate(
            commonName: commonName,
            serialSeed: serialSeed,
            publicKeyPKCS1: publicKeyData,
            signingKey: privateKey
        )
        let certificatePEM = PEMCodec.encode(label: "CERTIFICATE", der: certificateDER)
        return RSAPairingIdentityMaterial(privateKeyData: privateKeyData, certificatePEM: certificatePEM)
    }

    private func generatePrivateKey() throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let message = (error?.takeRetainedValue() as Error?)?.localizedDescription ?? "unknown error"
            throw MoonlightError(.unsupportedOperation, message: "Failed to generate RSA pairing key: \(message)")
        }
        return key
    }

    private func publicKey(from privateKey: SecKey) throws -> SecKey {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to extract RSA public key")
        }
        return publicKey
    }

    private func export(privateKey: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(privateKey, &error) as Data? else {
            let message = (error?.takeRetainedValue() as Error?)?.localizedDescription ?? "unknown error"
            throw MoonlightError(.unsupportedOperation, message: "Failed to export RSA private key: \(message)")
        }
        return data
    }

    private func export(publicKey: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            let message = (error?.takeRetainedValue() as Error?)?.localizedDescription ?? "unknown error"
            throw MoonlightError(.unsupportedOperation, message: "Failed to export RSA public key: \(message)")
        }
        return data
    }
}

private struct SelfSignedX509Builder {
    func makeCertificate(
        commonName: String,
        serialSeed: UUID,
        publicKeyPKCS1: Data,
        signingKey: SecKey
    ) throws -> Data {
        let algorithm = ASN1.sequence([
            ASN1.objectIdentifier([1, 2, 840, 113549, 1, 1, 11]),
            ASN1.null(),
        ])
        let name = ASN1.sequence([
            ASN1.set([
                ASN1.sequence([
                    ASN1.objectIdentifier([2, 5, 4, 3]),
                    ASN1.utf8String(commonName),
                ]),
            ]),
        ])
        let validity = ASN1.sequence([
            ASN1.utcTime(Date()),
            ASN1.utcTime(Calendar(identifier: .gregorian).date(byAdding: .year, value: 20, to: Date()) ?? Date().addingTimeInterval(60 * 60 * 24 * 365 * 20)),
        ])
        let subjectPublicKeyInfo = ASN1.sequence([
            ASN1.sequence([
                ASN1.objectIdentifier([1, 2, 840, 113549, 1, 1, 1]),
                ASN1.null(),
            ]),
            ASN1.bitString(publicKeyPKCS1),
        ])
        let tbsCertificate = ASN1.sequence([
            ASN1.explicit(tag: 0, contents: ASN1.integer(2)),
            ASN1.integer(serialNumber(seed: serialSeed)),
            algorithm,
            name,
            validity,
            name,
            subjectPublicKeyInfo,
        ])

        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            signingKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            tbsCertificate as CFData,
            &error
        ) as Data? else {
            let message = (error?.takeRetainedValue() as Error?)?.localizedDescription ?? "unknown error"
            throw MoonlightError(.unsupportedOperation, message: "Failed to sign X.509 certificate: \(message)")
        }

        return ASN1.sequence([
            tbsCertificate,
            algorithm,
            ASN1.bitString(signature),
        ])
    }

    private func serialNumber(seed: UUID) -> Data {
        let bytes = withUnsafeBytes(of: seed.uuid) { Data($0) }
        let trimmed = bytes.drop(while: { $0 == 0 })
        return trimmed.isEmpty ? Data([1]) : Data(trimmed)
    }
}
#endif

private enum PEMCodec {
    static func encode(label: String, der: Data) -> String {
        let base64 = der.base64EncodedString()
        let body = stride(from: 0, to: base64.count, by: 64).map { offset -> String in
            let start = base64.index(base64.startIndex, offsetBy: offset)
            let end = base64.index(start, offsetBy: min(64, base64.count - offset))
            return String(base64[start..<end])
        }.joined(separator: "\n")
        return "-----BEGIN \(label)-----\n\(body)\n-----END \(label)-----\n"
    }

    static func decodeCertificate(_ pemOrDER: Data) throws -> Data {
        try decode(pemOrDER)
    }

    private static func decode(_ pemOrDER: Data) throws -> Data {
        if pemOrDER.starts(with: Data("-----BEGIN ".utf8)) {
            guard let text = String(data: pemOrDER, encoding: .utf8) else {
                throw MoonlightError(.unsupportedOperation, message: "PEM payload is not valid UTF-8")
            }
            let base64Lines = text
                .split(whereSeparator: \.isNewline)
                .filter { !$0.hasPrefix("-----BEGIN ") && !$0.hasPrefix("-----END ") }
                .joined()

            guard let decoded = Data(base64Encoded: base64Lines) else {
                throw MoonlightError(.unsupportedOperation, message: "Failed to decode PEM payload")
            }
            return decoded
        }
        return pemOrDER
    }
}

private enum X509CertificateParser {
    static func signatureBytes(fromPEMOrDER pemOrDER: Data) throws -> Data {
        let der = try PEMCodec.decodeCertificate(pemOrDER)
        let root = try ASN1Node.parse(in: der, offset: 0)
        guard root.tag == 0x30 else {
            throw MoonlightError(.unsupportedOperation, message: "X.509 certificate root is not a sequence")
        }

        let children = try root.children(in: der)
        guard children.count >= 3 else {
            throw MoonlightError(.unsupportedOperation, message: "X.509 certificate is truncated")
        }

        let signatureValue = children[2]
        guard signatureValue.tag == 0x03 else {
            throw MoonlightError(.unsupportedOperation, message: "X.509 certificate signature is not a BIT STRING")
        }

        let bitString = signatureValue.content(in: der)
        guard let unusedBits = bitString.first, unusedBits == 0 else {
            throw MoonlightError(.unsupportedOperation, message: "X.509 certificate signature has unsupported BIT STRING padding")
        }
        return Data(bitString.dropFirst())
    }
}

private struct ASN1Node {
    let tag: UInt8
    let contentStart: Int
    let contentLength: Int
    let totalLength: Int

    static func parse(in data: Data, offset: Int) throws -> ASN1Node {
        guard offset + 2 <= data.count else {
            throw MoonlightError(.unsupportedOperation, message: "ASN.1 node is truncated")
        }

        let tag = data[offset]
        let lengthByte = data[offset + 1]
        var headerLength = 2
        let contentLength: Int

        if lengthByte & 0x80 == 0 {
            contentLength = Int(lengthByte)
        } else {
            let byteCount = Int(lengthByte & 0x7f)
            guard byteCount > 0, byteCount <= 4, offset + 2 + byteCount <= data.count else {
                throw MoonlightError(.unsupportedOperation, message: "ASN.1 length field is invalid")
            }

            var length = 0
            for index in 0..<byteCount {
                length = (length << 8) | Int(data[offset + 2 + index])
            }
            contentLength = length
            headerLength += byteCount
        }

        let totalLength = headerLength + contentLength
        guard offset + totalLength <= data.count else {
            throw MoonlightError(.unsupportedOperation, message: "ASN.1 node exceeds buffer length")
        }

        return ASN1Node(
            tag: tag,
            contentStart: offset + headerLength,
            contentLength: contentLength,
            totalLength: totalLength
        )
    }

    func children(in data: Data) throws -> [ASN1Node] {
        var nodes: [ASN1Node] = []
        var cursor = contentStart
        let end = contentStart + contentLength
        while cursor < end {
            let node = try ASN1Node.parse(in: data, offset: cursor)
            nodes.append(node)
            cursor += node.totalLength
        }
        guard cursor == end else {
            throw MoonlightError(.unsupportedOperation, message: "ASN.1 child parsing did not consume the full sequence")
        }
        return nodes
    }

    func content(in data: Data) -> Data {
        data.subdata(in: contentStart..<(contentStart + contentLength))
    }
}

private enum ASN1 {
    static func sequence(_ values: [Data]) -> Data {
        constructed(tag: 0x30, concatenate(values))
    }

    static func set(_ values: [Data]) -> Data {
        constructed(tag: 0x31, concatenate(values))
    }

    static func explicit(tag: UInt8, contents: Data) -> Data {
        constructed(tag: 0xa0 | tag, contents)
    }

    static func integer(_ value: Int) -> Data {
        integer(integerBytes(UInt64(value)))
    }

    static func integer(_ value: Data) -> Data {
        var bytes = Data(value.drop(while: { $0 == 0 }))
        if bytes.isEmpty {
            bytes = Data([0])
        }
        if let first = bytes.first, first & 0x80 != 0 {
            bytes.insert(0, at: bytes.startIndex)
        }
        return primitive(tag: 0x02, bytes)
    }

    static func objectIdentifier(_ components: [UInt64]) -> Data {
        precondition(components.count >= 2)
        var body = Data([UInt8(components[0] * 40 + components[1])])
        for component in components.dropFirst(2) {
            body.append(encodedBase128(component))
        }
        return primitive(tag: 0x06, body)
    }

    static func null() -> Data {
        primitive(tag: 0x05, Data())
    }

    static func utf8String(_ value: String) -> Data {
        primitive(tag: 0x0c, Data(value.utf8))
    }

    static func utcTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return primitive(tag: 0x17, Data(formatter.string(from: date).utf8))
    }

    static func bitString(_ value: Data) -> Data {
        primitive(tag: 0x03, Data([0]) + value)
    }

    private static func primitive(tag: UInt8, _ body: Data) -> Data {
        Data([tag]) + encodedLength(body.count) + body
    }

    private static func constructed(tag: UInt8, _ body: Data) -> Data {
        Data([tag]) + encodedLength(body.count) + body
    }

    private static func encodedLength(_ length: Int) -> Data {
        if length < 0x80 {
            return Data([UInt8(length)])
        }

        let bytes = integerBytes(UInt64(length))
        return Data([0x80 | UInt8(bytes.count)]) + bytes
    }

    private static func integerBytes(_ value: UInt64) -> Data {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            bytes.insert(UInt8(value & 0xff), at: 0)
            value >>= 8
        } while value > 0
        return Data(bytes)
    }

    private static func encodedBase128(_ value: UInt64) -> Data {
        var value = value
        var bytes: [UInt8] = [UInt8(value & 0x7f)]
        value >>= 7
        while value > 0 {
            bytes.insert(UInt8(value & 0x7f) | 0x80, at: 0)
            value >>= 7
        }
        return Data(bytes)
    }

    private static func concatenate(_ values: [Data]) -> Data {
        values.reduce(into: Data()) { partial, value in
            partial.append(value)
        }
    }
}

private extension URL {
    var fileSystemPath: String {
        path(percentEncoded: false)
    }
}
