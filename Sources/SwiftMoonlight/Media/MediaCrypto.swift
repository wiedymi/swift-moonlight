import CryptoKit
import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#endif

public struct VideoEncryptionContext: Sendable, Equatable {
    public var key: Data

    public init(key: Data) {
        self.key = key
    }
}

public struct AudioEncryptionContext: Sendable, Equatable {
    public var key: Data
    public var avRiKeyID: UInt32

    public init(key: Data, avRiKeyID: UInt32) {
        self.key = key
        self.avRiKeyID = avRiKeyID
    }
}

public struct EncryptedVideoHeader: Sendable, Equatable {
    public static let size = 32

    public var iv: Data
    public var frameNumber: UInt32
    public var tag: Data

    public init(iv: Data, frameNumber: UInt32, tag: Data) {
        self.iv = iv
        self.frameNumber = frameNumber
        self.tag = tag
    }
}

public struct VideoPacketDecryptor: Sendable {
    public init() {}

    public func parseEncryptedHeader(_ packet: Data) throws -> EncryptedVideoHeader {
        guard packet.count >= EncryptedVideoHeader.size else {
            throw MoonlightError(.invalidControlMessage, message: "Encrypted video packet is too short")
        }

        return EncryptedVideoHeader(
            iv: Data(packet[0..<12]),
            frameNumber: readUInt32LE(packet, offset: 12),
            tag: Data(packet[16..<32])
        )
    }

    public func decrypt(_ packet: Data, context: VideoEncryptionContext) throws -> Data {
        let header = try parseEncryptedHeader(packet)
        let ciphertext = packet.dropFirst(EncryptedVideoHeader.size)
        let key = SymmetricKey(data: context.key)
        let nonce = try AES.GCM.Nonce(data: header.iv)
        let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: header.tag)
        return try AES.GCM.open(sealed, using: key)
    }
}

public struct AudioPacketDecryptor: Sendable {
    public init() {}

    public func decrypt(_ packet: Data, context: AudioEncryptionContext) throws -> Data {
        guard packet.count >= RTPHeader.fixedSize else {
            throw MoonlightError(.invalidControlMessage, message: "Encrypted audio packet is too short")
        }

        let sequenceNumber = readUInt16BE(packet, offset: 2)
        let payload = Data(packet.dropFirst(RTPHeader.fixedSize))
        let decryptedPayload = try aesCBCDecrypt(
            payload,
            key: context.key,
            iv: makeAudioIV(avRiKeyID: context.avRiKeyID, sequenceNumber: sequenceNumber)
        )

        var decryptedPacket = Data(packet.prefix(RTPHeader.fixedSize))
        decryptedPacket.append(decryptedPayload)
        return decryptedPacket
    }

    public func makeAudioIV(avRiKeyID: UInt32, sequenceNumber: UInt16) -> Data {
        var iv = Data(repeating: 0, count: kCCBlockSizeAES128)
        let combined = avRiKeyID &+ UInt32(sequenceNumber)
        iv[0] = UInt8(truncatingIfNeeded: combined >> 24)
        iv[1] = UInt8(truncatingIfNeeded: combined >> 16)
        iv[2] = UInt8(truncatingIfNeeded: combined >> 8)
        iv[3] = UInt8(truncatingIfNeeded: combined)
        return iv
    }
}

public enum MediaCrypto {
    public static func encryptVideoPacket(
        _ plaintext: Data,
        frameNumber: UInt32,
        context: VideoEncryptionContext,
        iv: Data
    ) throws -> Data {
        let key = SymmetricKey(data: context.key)
        let nonce = try AES.GCM.Nonce(data: iv)
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)

        var packet = Data()
        packet.append(iv)
        packet.appendLE(frameNumber)
        packet.append(sealed.tag)
        packet.append(sealed.ciphertext)
        return packet
    }

    public static func encryptAudioPacket(
        rtpHeader: Data,
        payload: Data,
        context: AudioEncryptionContext,
        sequenceNumber: UInt16
    ) throws -> Data {
        guard rtpHeader.count == RTPHeader.fixedSize else {
            throw MoonlightError(.invalidControlMessage, message: "Audio RTP header size mismatch")
        }

        let encryptedPayload = try aesCBCEncrypt(
            payload,
            key: context.key,
            iv: AudioPacketDecryptor().makeAudioIV(avRiKeyID: context.avRiKeyID, sequenceNumber: sequenceNumber)
        )
        var packet = Data(rtpHeader)
        packet.append(encryptedPayload)
        return packet
    }
}

extension Data {
    fileprivate mutating func appendLE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 0))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}

private func readUInt16BE(_ data: Data, offset: Int) -> UInt16 {
    let b0 = UInt16(data[data.startIndex.advanced(by: offset)])
    let b1 = UInt16(data[data.startIndex.advanced(by: offset + 1)])
    return (b0 << 8) | b1
}

private func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
    let b0 = UInt32(data[data.startIndex.advanced(by: offset)])
    let b1 = UInt32(data[data.startIndex.advanced(by: offset + 1)])
    let b2 = UInt32(data[data.startIndex.advanced(by: offset + 2)])
    let b3 = UInt32(data[data.startIndex.advanced(by: offset + 3)])
    return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
}

private func aesCBCEncrypt(_ plaintext: Data, key: Data, iv: Data) throws -> Data {
    try aesCBC(operation: CCOperation(kCCEncrypt), input: plaintext, key: key, iv: iv)
}

private func aesCBCDecrypt(_ ciphertext: Data, key: Data, iv: Data) throws -> Data {
    try aesCBC(operation: CCOperation(kCCDecrypt), input: ciphertext, key: key, iv: iv)
}

private func aesCBC(operation: CCOperation, input: Data, key: Data, iv: Data) throws -> Data {
#if canImport(CommonCrypto)
    guard key.count == kCCKeySizeAES128 else {
        throw MoonlightError(.invalidControlMessage, message: "AES-CBC media key must be 16 bytes")
    }
    guard iv.count == kCCBlockSizeAES128 else {
        throw MoonlightError(.invalidControlMessage, message: "AES-CBC media IV must be 16 bytes")
    }

    var output = Data(repeating: 0, count: input.count + kCCBlockSizeAES128)
    let outputCapacity = output.count
    var outputLength = 0

    let status = output.withUnsafeMutableBytes { outputBytes in
        input.withUnsafeBytes { inputBytes in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    CCCrypt(
                        operation,
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress,
                        key.count,
                        ivBytes.baseAddress,
                        inputBytes.baseAddress,
                        input.count,
                        outputBytes.baseAddress,
                        outputCapacity,
                        &outputLength
                    )
                }
            }
        }
    }

    guard status == kCCSuccess else {
        throw MoonlightError(.invalidControlMessage, message: "AES-CBC media crypto failed with status \(status)")
    }

    output.removeSubrange(outputLength..<output.count)
    return output
#else
    throw MoonlightError(.unsupportedOperation, message: "AES-CBC media crypto requires CommonCrypto")
#endif
}
