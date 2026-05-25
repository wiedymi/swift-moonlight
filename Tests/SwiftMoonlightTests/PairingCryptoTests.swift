import CryptoKit
import Foundation
import Testing
@testable import SwiftMoonlight

private final class FixedRandomByteGenerator: @unchecked Sendable, RandomByteGenerator {
    private let values: [Data]
    private let lock = NSLock()
    private var index = 0

    init(values: [Data]) {
        self.values = values
    }

    func generate(count: Int) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard values.indices.contains(index), values[index].count == count else {
            throw MoonlightError(.unsupportedOperation, message: "Fixed random source exhausted")
        }
        defer { index += 1 }
        return values[index]
    }
}

private struct FixedSigner: PairingSigning {
    let signature: Data

    func sign(_ data: Data) throws -> Data {
        _ = data
        return signature
    }
}

@Test
func derivesAESKeyUsingSHA256ForGen7() throws {
    let salt = Data([0x00, 0x01, 0x02, 0x03])
    let key = PairingCrypto.deriveAESKey(pin: "1234", salt: salt, algorithm: .sha256)

    #expect(key.count == 16)
    #expect(key == Data(SHA256.hash(data: salt + Data("1234".utf8))).prefix(16))
}

@Test
func encryptsAndDecryptsPairingChallenge() throws {
    let key = Data((0..<16).map(UInt8.init))
    let plaintext = Data((16..<32).map(UInt8.init))

    let encrypted = try PairingCrypto.aesEncrypt(plaintext, key: key)
    let decrypted = try PairingCrypto.aesDecrypt(encrypted, key: key)

    #expect(decrypted == plaintext)
}

@Test
func buildsServerChallengeResponseHashAndPadsTo32Bytes() {
    let response = PairingCrypto.makeServerChallengeResponseHash(
        serverChallenge: Data([0x01, 0x02]),
        clientCertificateSignature: Data([0x03, 0x04]),
        clientSecret: Data([0x05, 0x06]),
        algorithm: .sha1
    )

    #expect(response.count == 32)
    #expect(response.prefix(20) == Data(Insecure.SHA1.hash(data: Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06]))))
    #expect(response.suffix(12) == Data(repeating: 0, count: 12))
}

@Test
func encryptsServerChallengeResponseHashBeforeSending() throws {
    let key = Data((0..<16).map(UInt8.init))
    let encrypted = try PairingCrypto.encryptServerChallengeResponse(
        serverChallenge: Data([0x01, 0x02]),
        clientCertificateSignature: Data([0x03, 0x04]),
        clientSecret: Data([0x05, 0x06]),
        aesKey: key,
        algorithm: .sha1
    )
    let decrypted = try PairingCrypto.aesDecrypt(encrypted, key: key)
    let expected = PairingCrypto.makeServerChallengeResponseHash(
        serverChallenge: Data([0x01, 0x02]),
        clientCertificateSignature: Data([0x03, 0x04]),
        clientSecret: Data([0x05, 0x06]),
        algorithm: .sha1
    )

    #expect(decrypted == expected)
}

@Test
func validatesServerResponseHash() {
    let randomChallenge = Data([0x10, 0x11])
    let serverSignature = Data([0x20, 0x21])
    let serverSecret = Data([0x30, 0x31])
    let expected = Data(SHA256.hash(data: randomChallenge + serverSignature + serverSecret))

    #expect(PairingCrypto.validateServerResponse(
        serverResponse: expected,
        randomChallenge: randomChallenge,
        serverCertificateSignature: serverSignature,
        serverSecret: serverSecret,
        algorithm: .sha256
    ))
}

@Test
func preparesPairingMaterialDeterministically() throws {
    let factory = PairingMaterialFactory(
        random: FixedRandomByteGenerator(values: [
            Data(repeating: 0xAA, count: 16),
            Data(repeating: 0xBB, count: 16),
            Data(repeating: 0xCC, count: 16),
        ])
    )
    let identity = PairingIdentityMaterial(
        clientCertificateHex: "AABBCCDD",
        certificateSignature: Data([0x01, 0x02, 0x03])
    )

    let prepared = try factory.prepare(
        pin: "1234",
        serverMajorVersion: 7,
        identity: identity,
        uniqueID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        deviceName: "MacBook Pro"
    )

    #expect(prepared.uniqueID.uuidString.lowercased() == "11111111-2222-3333-4444-555555555555")
    #expect(prepared.clientCertificateHex == "AABBCCDD")
    #expect(prepared.salt == Data(repeating: 0xAA, count: 16))
    #expect(prepared.randomChallenge == Data(repeating: 0xBB, count: 16))
    #expect(prepared.clientSecret == Data(repeating: 0xCC, count: 16))
    #expect(prepared.deviceName == "MacBook Pro")
    let expectedEncryptedChallenge = try PairingCrypto.aesEncrypt(prepared.randomChallenge, key: prepared.aesKey)
    #expect(prepared.encryptedClientChallenge == expectedEncryptedChallenge)
}

@Test
func buildsClientPairingSecretFromSigner() throws {
    let factory = PairingMaterialFactory(random: FixedRandomByteGenerator(values: []))
    let result = try factory.clientPairingSecretHex(
        clientSecret: Data([0x01, 0x02]),
        signer: FixedSigner(signature: Data([0xAA, 0xBB]))
    )

    #expect(result == "0102aabb")
}

@Test
func splitsServerPairingSecret() throws {
    let secret = try PairingCrypto.splitServerPairingSecret(Data((0..<20).map(UInt8.init)))

    #expect(secret.secret == Data((0..<16).map(UInt8.init)))
    #expect(secret.signature == Data((16..<20).map(UInt8.init)))
}
