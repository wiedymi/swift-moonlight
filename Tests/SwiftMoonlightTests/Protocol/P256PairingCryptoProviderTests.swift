import CryptoKit
import Foundation
import Testing
@testable import SwiftMoonlight

@Test
func p256PairingCryptoProviderReusesStoredIdentityMaterial() throws {
    let identity = ClientIdentity(identifier: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!, displayName: "swift-moonlight")
    let provider = P256PairingCryptoProvider(keyStore: EphemeralPairingPrivateKeyStore())

    let first = try provider.identityMaterial(for: identity)
    let second = try provider.identityMaterial(for: identity)

    #expect(first == second)
}

@Test
func p256PairingCryptoProviderSignsClientSecretWithStoredKey() throws {
    let identity = ClientIdentity(identifier: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, displayName: "swift-moonlight")
    let store = EphemeralPairingPrivateKeyStore()
    let provider = P256PairingCryptoProvider(keyStore: store)
    let secret = Data("client-secret".utf8)

    let identityMaterial = try provider.identityMaterial(for: identity)
    let signature = try provider.signClientSecret(secret, for: identity)

    let publicKey = try P256.Signing.PublicKey(x963Representation: Data(hexString: identityMaterial.clientCertificateHex))
    let ecdsaSignature = try P256.Signing.ECDSASignature(derRepresentation: signature)

    #expect(publicKey.isValidSignature(ecdsaSignature, for: secret))
}

@Test
func p256PairingCryptoProviderVerifiesServerSignatureAgainstCertificateMaterial() throws {
    let serverKey = P256.Signing.PrivateKey()
    let serverCertificateHex = serverKey.publicKey.x963Representation.hexString
    let secret = Data("server-secret".utf8)
    let signature = try serverKey.signature(for: secret).derRepresentation
    let provider = P256PairingCryptoProvider()

    #expect(try provider.verifyServerSignature(
        secret: secret,
        signature: signature,
        certificateHex: serverCertificateHex
    ))
}
