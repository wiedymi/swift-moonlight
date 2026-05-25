import CryptoKit
import Foundation
#if canImport(Security)
import Security
#endif
#if canImport(CommonCrypto)
import CommonCrypto
#endif

public enum PairingHashAlgorithm: Sendable, Equatable {
    case sha1
    case sha256

    public init(serverMajorVersion: Int) {
        self = serverMajorVersion >= 7 ? .sha256 : .sha1
    }

    public var digestLength: Int {
        switch self {
        case .sha1: return 20
        case .sha256: return 32
        }
    }
}

public struct PairingIdentityMaterial: Sendable, Equatable {
    public var clientCertificateHex: String
    public var certificateSignature: Data

    public init(clientCertificateHex: String, certificateSignature: Data) {
        self.clientCertificateHex = clientCertificateHex
        self.certificateSignature = certificateSignature
    }
}

public protocol PairingSigning: Sendable {
    func sign(_ data: Data) throws -> Data
}

public protocol RandomByteGenerator: Sendable {
    func generate(count: Int) throws -> Data
}

public struct SystemRandomByteGenerator: RandomByteGenerator {
    public init() {}

    public func generate(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to generate secure random bytes: \(status)")
        }
        return Data(bytes)
    }
}

public struct PairingPreparedMaterial: Sendable, Equatable {
    public var uniqueID: UUID
    public var clientCertificateHex: String
    public var salt: Data
    public var aesKey: Data
    public var randomChallenge: Data
    public var encryptedClientChallenge: Data
    public var clientSecret: Data
    public var deviceName: String?

    public init(
        uniqueID: UUID,
        clientCertificateHex: String,
        salt: Data,
        aesKey: Data,
        randomChallenge: Data,
        encryptedClientChallenge: Data,
        clientSecret: Data,
        deviceName: String?
    ) {
        self.uniqueID = uniqueID
        self.clientCertificateHex = clientCertificateHex
        self.salt = salt
        self.aesKey = aesKey
        self.randomChallenge = randomChallenge
        self.encryptedClientChallenge = encryptedClientChallenge
        self.clientSecret = clientSecret
        self.deviceName = deviceName
    }
}

public struct DecodedServerChallengeResponse: Sendable, Equatable {
    public var serverResponse: Data
    public var serverChallenge: Data

    public init(serverResponse: Data, serverChallenge: Data) {
        self.serverResponse = serverResponse
        self.serverChallenge = serverChallenge
    }
}

public enum PairingCrypto {
    public static func deriveAESKey(pin: String, salt: Data, algorithm: PairingHashAlgorithm) -> Data {
        let saltedPIN = salt + Data(pin.utf8)
        let digest: Data
        switch algorithm {
        case .sha1:
            digest = Data(Insecure.SHA1.hash(data: saltedPIN))
        case .sha256:
            digest = Data(SHA256.hash(data: saltedPIN))
        }
        return digest.prefix(16)
    }

    public static func hash(_ data: Data, algorithm: PairingHashAlgorithm) -> Data {
        switch algorithm {
        case .sha1:
            return Data(Insecure.SHA1.hash(data: data))
        case .sha256:
            return Data(SHA256.hash(data: data))
        }
    }

    public static func aesEncrypt(_ data: Data, key: Data) throws -> Data {
        try cryptECB(data, key: key, operation: CCOperation(kCCEncrypt))
    }

    public static func aesDecrypt(_ data: Data, key: Data) throws -> Data {
        try cryptECB(data, key: key, operation: CCOperation(kCCDecrypt))
    }

    public static func makeServerChallengeResponseHash(
        serverChallenge: Data,
        clientCertificateSignature: Data,
        clientSecret: Data,
        algorithm: PairingHashAlgorithm
    ) -> Data {
        let input = serverChallenge + clientCertificateSignature + clientSecret
        let digest = hash(input, algorithm: algorithm)
        return digest.padded(to: 32)
    }

    public static func encryptServerChallengeResponse(
        serverChallenge: Data,
        clientCertificateSignature: Data,
        clientSecret: Data,
        aesKey: Data,
        algorithm: PairingHashAlgorithm
    ) throws -> Data {
        let responseHash = makeServerChallengeResponseHash(
            serverChallenge: serverChallenge,
            clientCertificateSignature: clientCertificateSignature,
            clientSecret: clientSecret,
            algorithm: algorithm
        )
        return try aesEncrypt(responseHash, key: aesKey)
    }

    public static func validateServerResponse(
        serverResponse: Data,
        randomChallenge: Data,
        serverCertificateSignature: Data,
        serverSecret: Data,
        algorithm: PairingHashAlgorithm
    ) -> Bool {
        let expected = hash(randomChallenge + serverCertificateSignature + serverSecret, algorithm: algorithm)
        return expected == serverResponse
    }

    public static func splitServerPairingSecret(_ data: Data) throws -> (secret: Data, signature: Data) {
        guard data.count > 16 else {
            throw MoonlightError(.pairingRejected, message: "Pairing secret response is too short")
        }
        return (Data(data.prefix(16)), Data(data.dropFirst(16)))
    }

    public static func makeClientPairingSecret(clientSecret: Data, signature: Data) -> Data {
        clientSecret + signature
    }

    public static func decodeServerChallengeResponse(
        _ encryptedResponse: Data,
        key: Data,
        algorithm: PairingHashAlgorithm
    ) throws -> DecodedServerChallengeResponse {
        let decrypted = try aesDecrypt(encryptedResponse, key: key)
        let minimumLength = algorithm.digestLength + 16
        guard decrypted.count >= minimumLength else {
            throw MoonlightError(.pairingRejected, message: "Server challenge response is too short")
        }

        return DecodedServerChallengeResponse(
            serverResponse: Data(decrypted.prefix(algorithm.digestLength)),
            serverChallenge: Data(decrypted.dropFirst(algorithm.digestLength).prefix(16))
        )
    }

    private static func cryptECB(_ data: Data, key: Data, operation: CCOperation) throws -> Data {
        #if canImport(CommonCrypto)
        guard key.count == kCCKeySizeAES128 else {
            throw MoonlightError(.unsupportedOperation, message: "Pairing AES key must be 16 bytes")
        }
        guard data.count.isMultiple(of: kCCBlockSizeAES128) else {
            throw MoonlightError(.unsupportedOperation, message: "Pairing AES input must be block aligned")
        }

        let outputCapacity = data.count
        var output = Data(count: outputCapacity)
        var outLength = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        operation,
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress,
                        key.count,
                        nil,
                        dataBytes.baseAddress,
                        data.count,
                        outputBytes.baseAddress,
                        outputCapacity,
                        &outLength
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw MoonlightError(.unsupportedOperation, message: "Pairing AES operation failed: \(status)")
        }
        output.count = outLength
        return output
        #else
        throw MoonlightError(.unsupportedOperation, message: "CommonCrypto is unavailable for pairing AES operations")
        #endif
    }
}

public struct PairingMaterialFactory: Sendable {
    public let random: any RandomByteGenerator

    public init(random: any RandomByteGenerator = SystemRandomByteGenerator()) {
        self.random = random
    }

    public func prepare(
        pin: String,
        serverMajorVersion: Int,
        identity: PairingIdentityMaterial,
        uniqueID: UUID = UUID(),
        deviceName: String? = nil
    ) throws -> PairingPreparedMaterial {
        let algorithm = PairingHashAlgorithm(serverMajorVersion: serverMajorVersion)
        let salt = try random.generate(count: 16)
        let aesKey = PairingCrypto.deriveAESKey(pin: pin, salt: salt, algorithm: algorithm)
        let randomChallenge = try random.generate(count: 16)
        let encryptedClientChallenge = try PairingCrypto.aesEncrypt(randomChallenge, key: aesKey)
        let clientSecret = try random.generate(count: 16)

        return PairingPreparedMaterial(
            uniqueID: uniqueID,
            clientCertificateHex: identity.clientCertificateHex,
            salt: salt,
            aesKey: aesKey,
            randomChallenge: randomChallenge,
            encryptedClientChallenge: encryptedClientChallenge,
            clientSecret: clientSecret,
            deviceName: deviceName
        )
    }

    public func serverChallengeResponseHex(
        encryptedServerChallengeResponse: Data,
        prepared: PairingPreparedMaterial,
        identity: PairingIdentityMaterial,
        serverMajorVersion: Int
    ) throws -> String {
        let algorithm = PairingHashAlgorithm(serverMajorVersion: serverMajorVersion)
        let decoded = try PairingCrypto.decodeServerChallengeResponse(
            encryptedServerChallengeResponse,
            key: prepared.aesKey,
            algorithm: algorithm
        )
        let challengeResponse = try PairingCrypto.encryptServerChallengeResponse(
            serverChallenge: decoded.serverChallenge,
            clientCertificateSignature: identity.certificateSignature,
            clientSecret: prepared.clientSecret,
            aesKey: prepared.aesKey,
            algorithm: algorithm
        )
        return challengeResponse.hexString
    }

    public func clientPairingSecretHex(clientSecret: Data, signer: any PairingSigning) throws -> String {
        let signature = try signer.sign(clientSecret)
        return PairingCrypto.makeClientPairingSecret(clientSecret: clientSecret, signature: signature).hexString
    }
}

extension Data {
    func padded(to size: Int) -> Data {
        guard count < size else {
            return self
        }
        var data = self
        data.append(contentsOf: repeatElement(0, count: size - count))
        return data
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init(hexString: String) throws {
        let normalized = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count.isMultiple(of: 2) else {
            throw MoonlightError(.pairingRejected, message: "Hex string has odd length")
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(normalized.count / 2)
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let nextIndex = normalized.index(index, offsetBy: 2)
            let byteString = normalized[index..<nextIndex]
            guard let byte = UInt8(byteString, radix: 16) else {
                throw MoonlightError(.pairingRejected, message: "Hex string contains invalid bytes")
            }
            bytes.append(byte)
            index = nextIndex
        }

        self.init(bytes)
    }
}
