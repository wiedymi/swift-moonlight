import Foundation
import Testing
@testable import SwiftMoonlight

@Test
func generatedRSAPairingCryptoProviderEmitsPEMCertificateMaterial() throws {
    let provider = GeneratedRSAPairingCryptoProvider()
    let identity = ClientIdentity(
        identifier: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        displayName: "Tester"
    )

    let material = try provider.identityMaterial(for: identity)
    let certificateData = try decodeHex(material.clientCertificateHex)
    guard let certificateText = String(data: certificateData, encoding: .utf8) else {
        throw MoonlightError(.unsupportedOperation, message: "Generated certificate is not valid UTF-8 PEM")
    }

    #expect(certificateText.contains("BEGIN CERTIFICATE"))
    #expect(!material.certificateSignature.isEmpty)
}

@Test
func generatedRSAPairingCryptoProviderSignsAndVerifiesWithCertificate() throws {
    let provider = GeneratedRSAPairingCryptoProvider()
    let identity = ClientIdentity(
        identifier: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        displayName: "Tester"
    )
    let payload = Data("pairing-secret".utf8)

    let signature = try provider.signClientSecret(payload, for: identity)
    let material = try provider.identityMaterial(for: identity)

    #expect(
        try provider.verifyServerSignature(
            secret: payload,
            signature: signature,
            certificateHex: material.clientCertificateHex
        )
    )
}

@Test
func fileRSAPairingIdentityStorePersistsMaterialAcrossLoads() throws {
    let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let store = FileRSAPairingIdentityStore(fileURL: tempDirectory.appending(path: "pairing-identity.json"))
    let identity = ClientIdentity(
        identifier: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        displayName: "Tester"
    )

    let first = try store.loadOrCreateIdentityMaterial(for: identity)
    let second = try store.loadOrCreateIdentityMaterial(for: identity)

    #expect(first == second)
}

private func decodeHex(_ hex: String) throws -> Data {
    let normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.count.isMultiple(of: 2) else {
        throw MoonlightError(.unsupportedOperation, message: "Hex string must contain an even number of digits")
    }

    var bytes = Data()
    bytes.reserveCapacity(normalized.count / 2)

    var index = normalized.startIndex
    while index < normalized.endIndex {
        let next = normalized.index(index, offsetBy: 2)
        guard let byte = UInt8(normalized[index..<next], radix: 16) else {
            throw MoonlightError(.unsupportedOperation, message: "Hex string contains invalid digits")
        }
        bytes.append(byte)
        index = next
    }

    return bytes
}
