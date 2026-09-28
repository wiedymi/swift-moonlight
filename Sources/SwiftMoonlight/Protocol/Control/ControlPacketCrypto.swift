import CryptoKit
import Foundation

public enum ControlEncryptionVersion: Sendable, Equatable {
    case legacy
    case v2
}

public enum ControlPacketSender: Sendable, Equatable {
    case client
    case host
}

public struct ControlEncryptionContext: Sendable, Equatable {
    public var key: Data
    public var version: ControlEncryptionVersion

    public init(key: Data, version: ControlEncryptionVersion) {
        self.key = key
        self.version = version
    }
}

public struct DecryptedControlPacket: Sendable, Equatable {
    public var sequenceNumber: UInt32
    public var packetType: UInt16
    public var payload: Data
    public var packet: Data

    public init(sequenceNumber: UInt32, packetType: UInt16, payload: Data, packet: Data) {
        self.sequenceNumber = sequenceNumber
        self.packetType = packetType
        self.payload = payload
        self.packet = packet
    }
}

public struct ControlPacketCrypto {
    public static let encryptedHeaderType: UInt16 = 0x0001
    public static let authenticationTagLength = 16

    public init() {}

    public func seal(
        packetType: UInt16,
        payload: Data,
        sequenceNumber: UInt32,
        sender: ControlPacketSender,
        context: ControlEncryptionContext
    ) throws -> Data {
        let plaintext = encodePlaintextPacket(packetType: packetType, payload: payload)
        let key = SymmetricKey(data: context.key)
        let nonceData = try makeNonce(
            sequenceNumber: sequenceNumber,
            sender: sender,
            version: context.version
        )
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)

        guard sealed.tag.count == Self.authenticationTagLength else {
            throw MoonlightError(.invalidControlMessage, message: "Unexpected AES-GCM tag length")
        }

        var packet = Data()
        packet.appendLE(Self.encryptedHeaderType)
        packet.appendLE(UInt16(4 + Self.authenticationTagLength + plaintext.count))
        packet.appendLE(sequenceNumber)
        packet.append(sealed.tag)
        packet.append(sealed.ciphertext)
        return packet
    }

    public func open(
        packet: Data,
        sender: ControlPacketSender,
        context: ControlEncryptionContext
    ) throws -> DecryptedControlPacket {
        guard packet.count >= 8 + Self.authenticationTagLength + 4 else {
            throw MoonlightError(.invalidControlMessage, message: "Encrypted control packet is too short")
        }

        let headerType = readUInt16LE(from: packet, at: 0)
        guard headerType == Self.encryptedHeaderType else {
            throw MoonlightError(.invalidControlMessage, message: "Unexpected encrypted control header type")
        }

        let declaredLength = Int(readUInt16LE(from: packet, at: 2))
        let expectedLength = declaredLength + 4
        guard packet.count == expectedLength else {
            throw MoonlightError(.invalidControlMessage, message: "Encrypted control packet length mismatch")
        }

        let sequenceNumber = readUInt32LE(from: packet, at: 4)
        let tagStart = 8
        let ciphertextStart = tagStart + Self.authenticationTagLength
        let tag = packet[tagStart..<ciphertextStart]
        let ciphertext = packet[ciphertextStart..<packet.count]

        let key = SymmetricKey(data: context.key)
        let nonceData = try makeNonce(
            sequenceNumber: sequenceNumber,
            sender: sender,
            version: context.version
        )
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let plaintext = try AES.GCM.open(sealed, using: key)

        guard plaintext.count >= 4 else {
            throw MoonlightError(.invalidControlMessage, message: "Decrypted control packet is too short")
        }

        let packetType = readUInt16LE(from: plaintext, at: 0)
        let payloadLength = Int(readUInt16LE(from: plaintext, at: 2))
        guard plaintext.count >= 4 + payloadLength else {
            throw MoonlightError(.invalidControlMessage, message: "Decrypted control packet payload overruns plaintext")
        }

        let payload = plaintext[4..<(4 + payloadLength)]
        let v1Packet = Data(plaintext[0..<2]) + payload

        return DecryptedControlPacket(
            sequenceNumber: sequenceNumber,
            packetType: packetType,
            payload: Data(payload),
            packet: v1Packet
        )
    }

    private func encodePlaintextPacket(packetType: UInt16, payload: Data) -> Data {
        var plaintext = Data()
        plaintext.appendLE(packetType)
        plaintext.appendLE(UInt16(payload.count))
        plaintext.append(payload)
        return plaintext
    }

    private func makeNonce(
        sequenceNumber: UInt32,
        sender: ControlPacketSender,
        version: ControlEncryptionVersion
    ) throws -> Data {
        var iv = Data(repeating: 0, count: 16)

        switch version {
        case .legacy:
            iv[0] = UInt8(truncatingIfNeeded: sequenceNumber)
            return iv

        case .v2:
            iv[0] = UInt8(truncatingIfNeeded: sequenceNumber >> 0)
            iv[1] = UInt8(truncatingIfNeeded: sequenceNumber >> 8)
            iv[2] = UInt8(truncatingIfNeeded: sequenceNumber >> 16)
            iv[3] = UInt8(truncatingIfNeeded: sequenceNumber >> 24)
            iv[10] = sender == .client ? Character("C").asciiValue! : Character("H").asciiValue!
            iv[11] = Character("C").asciiValue!
            return iv.prefix(12)
        }
    }
}

extension Data {
    fileprivate mutating func appendLE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 0))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    fileprivate mutating func appendLE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 0))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}

private func readUInt8(from bytes: Data, at offset: Int) -> UInt8 {
    bytes[bytes.startIndex.advanced(by: offset)]
}

private func readUInt16LE(from bytes: Data, at offset: Int) -> UInt16 {
    let b0 = UInt16(readUInt8(from: bytes, at: offset))
    let b1 = UInt16(readUInt8(from: bytes, at: offset + 1))
    return b0 | (b1 << 8)
}

private func readUInt32LE(from bytes: Data, at offset: Int) -> UInt32 {
    let b0 = UInt32(readUInt8(from: bytes, at: offset))
    let b1 = UInt32(readUInt8(from: bytes, at: offset + 1))
    let b2 = UInt32(readUInt8(from: bytes, at: offset + 2))
    let b3 = UInt32(readUInt8(from: bytes, at: offset + 3))
    return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
}
