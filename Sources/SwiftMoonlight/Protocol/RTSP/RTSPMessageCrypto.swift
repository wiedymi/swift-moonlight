import CryptoKit
import Foundation

struct EncryptedRTSPEnvelope: Sendable, Equatable {
    static let encryptedMessageBit: UInt32 = 0x8000_0000
    static let tagLength = 16
    static let headerLength = 4 + 4 + tagLength

    var sequenceNumber: UInt32
    var tag: Data
    var ciphertext: Data

    var payloadLength: Int {
        ciphertext.count
    }

    func serialized() throws -> Data {
        guard tag.count == Self.tagLength else {
            throw MoonlightError(.unsupportedOperation, message: "Encrypted RTSP tag must be 16 bytes")
        }

        var data = Data()
        data.append(contentsOf: (Self.encryptedMessageBit | UInt32(payloadLength)).bigEndianBytes)
        data.append(contentsOf: sequenceNumber.bigEndianBytes)
        data.append(tag)
        data.append(ciphertext)
        return data
    }

    static func parse(from data: Data) throws -> EncryptedRTSPEnvelope {
        guard data.count >= headerLength else {
            throw MoonlightError(.invalidLaunchResponse, message: "Encrypted RTSP header is too short")
        }

        let typeAndLength = try UInt32(bigEndianData: data.prefix(4))
        guard (typeAndLength & encryptedMessageBit) != 0 else {
            throw MoonlightError(.invalidLaunchResponse, message: "Encrypted RTSP packet is missing the encryption flag")
        }

        let payloadLength = Int(typeAndLength & ~encryptedMessageBit)
        let expectedLength = headerLength + payloadLength
        guard data.count == expectedLength else {
            throw MoonlightError(.invalidLaunchResponse, message: "Encrypted RTSP packet length does not match header")
        }

        return EncryptedRTSPEnvelope(
            sequenceNumber: try UInt32(bigEndianData: data[4..<8]),
            tag: Data(data[8..<(8 + tagLength)]),
            ciphertext: Data(data[headerLength..<expectedLength])
        )
    }
}

struct RTSPMessageCrypto: Sendable {
    enum Direction: Sendable {
        case clientToHost
        case hostToClient

        fileprivate var marker: (UInt8, UInt8) {
            switch self {
            case .clientToHost:
                return (UInt8(ascii: "C"), UInt8(ascii: "R"))
            case .hostToClient:
                return (UInt8(ascii: "H"), UInt8(ascii: "R"))
            }
        }
    }

    func encrypt(_ plaintext: Data, key: Data, sequenceNumber: UInt32, direction: Direction) throws -> Data {
        let sealed = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: key),
            nonce: try AES.GCM.Nonce(data: nonceData(sequenceNumber: sequenceNumber, direction: direction))
        )

        let envelope = EncryptedRTSPEnvelope(
            sequenceNumber: sequenceNumber,
            tag: sealed.tag,
            ciphertext: sealed.ciphertext
        )
        return try envelope.serialized()
    }

    func decrypt(_ packet: Data, key: Data, direction: Direction) throws -> Data {
        let envelope = try EncryptedRTSPEnvelope.parse(from: packet)
        let sealed = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonceData(sequenceNumber: envelope.sequenceNumber, direction: direction)),
            ciphertext: envelope.ciphertext,
            tag: envelope.tag
        )
        return try AES.GCM.open(sealed, using: SymmetricKey(data: key))
    }

    private func nonceData(sequenceNumber: UInt32, direction: Direction) -> Data {
        let markers = direction.marker
        return Data([
            UInt8(truncatingIfNeeded: sequenceNumber),
            UInt8(truncatingIfNeeded: sequenceNumber >> 8),
            UInt8(truncatingIfNeeded: sequenceNumber >> 16),
            UInt8(truncatingIfNeeded: sequenceNumber >> 24),
            0, 0, 0, 0, 0, 0,
            markers.0,
            markers.1,
        ])
    }
}

extension UInt32 {
    var bigEndianBytes: [UInt8] {
        withUnsafeBytes(of: bigEndian, Array.init)
    }

    init(bigEndianData: some DataProtocol) throws {
        let raw = Data(bigEndianData)
        guard raw.count == 4 else {
            throw MoonlightError(.invalidLaunchResponse, message: "Encrypted RTSP integer field must be 4 bytes")
        }
        self = raw.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    }
}
