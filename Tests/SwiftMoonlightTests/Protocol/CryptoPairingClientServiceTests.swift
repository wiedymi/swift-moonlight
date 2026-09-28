import CryptoKit
import Foundation
import Testing
@testable import SwiftMoonlight

private final class PairingFixedRandom: @unchecked Sendable, RandomByteGenerator {
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

private struct FixturePairingCryptoProvider: PairingCryptoProvider {
    let identityMaterialValue: PairingIdentityMaterial
    let clientSignature: Data
    let serverCertificateSignatureValue: Data
    let serverSecretSignatureValue: Data

    func identityMaterial(for identity: ClientIdentity) throws -> PairingIdentityMaterial {
        _ = identity
        return identityMaterialValue
    }

    func signClientSecret(_ clientSecret: Data, for identity: ClientIdentity) throws -> Data {
        _ = clientSecret
        _ = identity
        return clientSignature
    }

    func serverCertificateSignature(certificateHex: String) throws -> Data {
        _ = certificateHex
        return serverCertificateSignatureValue
    }

    func verifyServerSignature(secret: Data, signature: Data, certificateHex: String) throws -> Bool {
        _ = secret
        _ = certificateHex
        return signature == serverSecretSignatureValue
    }
}

@Test
func cryptoPairingClientServiceCompletesHandshakeAndVerification() async throws {
    let host = MoonlightHost(
        id: HostID(),
        name: "Sunshine",
        endpoint: .init(address: "192.168.1.10", port: 47990),
        kind: .sunshine,
        pairingState: .unpaired,
        capabilities: .default
    )
    let identity = ClientIdentity(
        identifier: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        displayName: "Tester"
    )
    let identityMaterial = PairingIdentityMaterial(
        clientCertificateHex: "aabbccdd",
        certificateSignature: Data([0x21, 0x22, 0x23, 0x24])
    )
    let cryptoProvider = FixturePairingCryptoProvider(
        identityMaterialValue: identityMaterial,
        clientSignature: Data([0x91, 0x92, 0x93]),
        serverCertificateSignatureValue: Data([0x31, 0x32, 0x33, 0x34]),
        serverSecretSignatureValue: Data([0x41, 0x42, 0x43, 0x44])
    )
    let random = PairingFixedRandom(values: [
        Data(repeating: 0xAA, count: 16),
        Data(repeating: 0xBB, count: 16),
        Data(repeating: 0xCC, count: 16),
    ])
    let materialFactory = PairingMaterialFactory(random: random)
    let prepared = try materialFactory.prepare(
        pin: "1234",
        serverMajorVersion: 7,
        identity: identityMaterial,
        uniqueID: identity.identifier,
        deviceName: identity.displayName
    )
    let serverSecret = Data(repeating: 0xDD, count: 16)
    let serverChallenge = Data(repeating: 0xEE, count: 16)
    let serverResponse = PairingCrypto.hash(
        prepared.randomChallenge + cryptoProvider.serverCertificateSignatureValue + serverSecret,
        algorithm: .sha256
    )
    let encryptedChallengeResponse = try PairingCrypto.aesEncrypt(
        serverResponse + serverChallenge,
        key: prepared.aesKey
    )
    let transport = FixturePairingTransport(responses: [
        pairingXML(plainCertificateHex: "cafebabe"),
        pairingXML(challengeResponseHex: encryptedChallengeResponse.hexString),
        pairingXML(pairingSecretHex: (serverSecret + cryptoProvider.serverSecretSignatureValue).hexString),
        pairingXML(),
        pairingXML(),
    ])
    let service = CryptoPairingClientService(
        transport: transport,
        materialFactory: PairingMaterialFactory(random: PairingFixedRandom(values: [
            Data(repeating: 0xAA, count: 16),
            Data(repeating: 0xBB, count: 16),
            Data(repeating: 0xCC, count: 16),
        ])),
        cryptoProvider: cryptoProvider
    )

    let result = try await service.pair(host: host, pin: "1234", identity: identity)
    let requests = await transport.recordedRequests()
    let expectedServerChallengeResponseHex = try PairingCrypto.encryptServerChallengeResponse(
        serverChallenge: serverChallenge,
        clientCertificateSignature: identityMaterial.certificateSignature,
        clientSecret: prepared.clientSecret,
        aesKey: prepared.aesKey,
        algorithm: .sha256
    ).hexString
    let expectedClientPairingSecretHex = PairingCrypto.makeClientPairingSecret(
        clientSecret: prepared.clientSecret,
        signature: cryptoProvider.clientSignature
    ).hexString

    #expect(result.hostID == host.id)
    #expect(result.state == .paired)
    #expect(requests.count == 5)
    #expect(requests[0].queryItems.contains(.init(name: "phrase", value: "getservercert")))
    #expect(requests[0].queryItems.contains(.init(name: "clientcert", value: "aabbccdd")))
    #expect(requests[1].queryItems.contains(.init(name: "clientchallenge", value: prepared.encryptedClientChallenge.hexString.lowercased())))
    #expect(requests[2].queryItems.contains(.init(name: "serverchallengeresp", value: expectedServerChallengeResponseHex.lowercased())))
    #expect(requests[3].queryItems.contains(.init(name: "clientpairingsecret", value: expectedClientPairingSecretHex.lowercased())))
    #expect(requests[4].queryItems.contains(.init(name: "phrase", value: "pairchallenge")))
}

@Test
func cryptoPairingClientServiceRejectsIncorrectPinResponse() async throws {
    let host = MoonlightHost(
        id: HostID(),
        name: "Sunshine",
        endpoint: .init(address: "192.168.1.10", port: 47990),
        kind: .sunshine,
        pairingState: .unpaired,
        capabilities: .default
    )
    let identity = ClientIdentity(
        identifier: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        displayName: "Tester"
    )
    let identityMaterial = PairingIdentityMaterial(
        clientCertificateHex: "aabbccdd",
        certificateSignature: Data([0x21, 0x22, 0x23, 0x24])
    )
    let cryptoProvider = FixturePairingCryptoProvider(
        identityMaterialValue: identityMaterial,
        clientSignature: Data([0x91, 0x92, 0x93]),
        serverCertificateSignatureValue: Data([0x31, 0x32, 0x33, 0x34]),
        serverSecretSignatureValue: Data([0x41, 0x42, 0x43, 0x44])
    )
    let prepared = try PairingMaterialFactory(random: PairingFixedRandom(values: [
        Data(repeating: 0xAA, count: 16),
        Data(repeating: 0xBB, count: 16),
        Data(repeating: 0xCC, count: 16),
    ])).prepare(
        pin: "1234",
        serverMajorVersion: 7,
        identity: identityMaterial,
        uniqueID: identity.identifier,
        deviceName: identity.displayName
    )
    let badServerResponse = Data(repeating: 0x99, count: 32)
    let serverChallenge = Data(repeating: 0xEE, count: 16)
    let encryptedChallengeResponse = try PairingCrypto.aesEncrypt(
        badServerResponse + serverChallenge,
        key: prepared.aesKey
    )
    let transport = FixturePairingTransport(responses: [
        pairingXML(plainCertificateHex: "cafebabe"),
        pairingXML(challengeResponseHex: encryptedChallengeResponse.hexString),
        pairingXML(pairingSecretHex: (Data(repeating: 0xDD, count: 16) + cryptoProvider.serverSecretSignatureValue).hexString),
    ])
    let service = CryptoPairingClientService(
        transport: transport,
        materialFactory: PairingMaterialFactory(random: PairingFixedRandom(values: [
            Data(repeating: 0xAA, count: 16),
            Data(repeating: 0xBB, count: 16),
            Data(repeating: 0xCC, count: 16),
        ])),
        cryptoProvider: cryptoProvider,
        performPairChallengeVerification: false
    )

    await #expect(throws: MoonlightError.self) {
        _ = try await service.pair(host: host, pin: "1234", identity: identity)
    }
}

@Test
func cryptoPairingClientServiceIncludesApolloOTPAuthOnGetServerCert() async throws {
    let host = MoonlightHost(
        id: HostID(),
        name: "Apollo",
        endpoint: .init(address: "192.168.1.20", port: 47990),
        kind: .apollo,
        pairingState: .unpaired,
        capabilities: .init(supportsOTPAuth: true)
    )
    let identity = ClientIdentity(
        identifier: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        displayName: "Tester"
    )
    let identityMaterial = PairingIdentityMaterial(
        clientCertificateHex: "aabbccdd",
        certificateSignature: Data([0x21, 0x22, 0x23, 0x24])
    )
    let cryptoProvider = FixturePairingCryptoProvider(
        identityMaterialValue: identityMaterial,
        clientSignature: Data([0x91, 0x92, 0x93]),
        serverCertificateSignatureValue: Data([0x31, 0x32, 0x33, 0x34]),
        serverSecretSignatureValue: Data([0x41, 0x42, 0x43, 0x44])
    )
    let prepared = try PairingMaterialFactory(random: PairingFixedRandom(values: [
        Data(repeating: 0xAA, count: 16),
        Data(repeating: 0xBB, count: 16),
        Data(repeating: 0xCC, count: 16),
    ])).prepare(
        pin: "1234",
        serverMajorVersion: 7,
        identity: identityMaterial,
        uniqueID: identity.identifier,
        deviceName: identity.displayName
    )
    let serverSecret = Data(repeating: 0xDD, count: 16)
    let serverChallenge = Data(repeating: 0xEE, count: 16)
    let serverResponse = PairingCrypto.hash(
        prepared.randomChallenge + cryptoProvider.serverCertificateSignatureValue + serverSecret,
        algorithm: .sha256
    )
    let encryptedChallengeResponse = try PairingCrypto.aesEncrypt(
        serverResponse + serverChallenge,
        key: prepared.aesKey
    )
    let transport = FixturePairingTransport(responses: [
        pairingXML(plainCertificateHex: "cafebabe"),
        pairingXML(challengeResponseHex: encryptedChallengeResponse.hexString),
        pairingXML(pairingSecretHex: (serverSecret + cryptoProvider.serverSecretSignatureValue).hexString),
        pairingXML(),
        pairingXML(),
    ])
    let service = CryptoPairingClientService(
        transport: transport,
        materialFactory: PairingMaterialFactory(random: PairingFixedRandom(values: [
            Data(repeating: 0xAA, count: 16),
            Data(repeating: 0xBB, count: 16),
            Data(repeating: 0xCC, count: 16),
        ])),
        cryptoProvider: cryptoProvider
    )

    _ = try await service.pair(
        host: host,
        auth: .otp(pin: "1234", passphrase: "apollo-passphrase"),
        identity: identity
    )

    let requests = await transport.recordedRequests()
    let expectedOTPAuth = Data(
        SHA256.hash(data: Data("1234\(prepared.salt.hexString.lowercased())apollo-passphrase".utf8))
    ).hexString.lowercased()

    #expect(requests[0].queryItems.contains(.init(name: "devicename", value: "Tester")))
    #expect(requests[0].queryItems.contains(.init(name: "otpauth", value: expectedOTPAuth)))
}

private func pairingXML(
    plainCertificateHex: String? = nil,
    challengeResponseHex: String? = nil,
    pairingSecretHex: String? = nil
) -> Data {
    var body = """
    <?xml version="1.0" encoding="utf-8"?>
    <root status_code="200">
      <paired>1</paired>
    """

    if let plainCertificateHex {
        body += "\n  <plaincert>\(plainCertificateHex)</plaincert>"
    }
    if let challengeResponseHex {
        body += "\n  <challengeresponse>\(challengeResponseHex)</challengeresponse>"
    }
    if let pairingSecretHex {
        body += "\n  <pairingsecret>\(pairingSecretHex)</pairingsecret>"
    }

    body += "\n</root>\n"
    return Data(body.utf8)
}
