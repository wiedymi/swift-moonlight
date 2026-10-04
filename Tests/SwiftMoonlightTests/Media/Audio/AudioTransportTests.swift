import CoreGraphics
import Foundation
import Testing
@testable import SwiftMoonlight
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Test
func decryptsEncryptedAudioPacket() throws {
    let key = Data("0123456789ABCDEF".utf8)
    let context = AudioEncryptionContext(key: key, avRiKeyID: 0x1020_3040)
    let plaintext = makeAudioPacket(sequenceNumber: 20, timestamp: 48_000, payload: Data([0xF8, 0xFF, 0xFE]))
    let encrypted = try MediaCrypto.encryptAudioPacket(
        rtpHeader: Data(plaintext.prefix(RTPHeader.fixedSize)),
        payload: Data(plaintext.dropFirst(RTPHeader.fixedSize)),
        context: context,
        sequenceNumber: 20
    )

    let decryptor = AudioPacketDecryptor()
    let decrypted = try decryptor.decrypt(encrypted, context: context)
    let expectedIV = decryptor.makeAudioIV(avRiKeyID: 0x1020_3040, sequenceNumber: 20)

    #expect(expectedIV.prefix(4) == Data([0x10, 0x20, 0x30, 0x54]))
    #expect(decrypted == plaintext)
}

@Test
func parsesAndDepacketizesAudioPacket() async throws {
    let parser = AudioPacketParser()
    let depacketizer = SimpleAudioDepacketizer()
    let raw = makeAudioPacket(sequenceNumber: 20, timestamp: 48_000, payload: Data([0xF8, 0xFF, 0xFE]))

    let packet = try parser.parse(raw)
    let encoded = try #require(try await depacketizer.submit(packet))

    #expect(packet.rtp.sequenceNumber == 20)
    #expect(encoded.timestamp == 48_000)
    #expect(encoded.payload.hexString == "F8FFFE")
}

@Test
func zeroAudioReorderWindowStillEmitsFirstPacket() async throws {
    let depacketizer = SimpleAudioDepacketizer(reorderWindowSize: 0)
    let packet = try AudioPacketParser().parse(
        makeAudioPacket(sequenceNumber: 20, timestamp: 48_000, payload: Data([0xAB]))
    )

    let encoded = try await depacketizer.submit(packet)

    #expect(encoded?.payload == Data([0xAB]))
    #expect(await depacketizer.snapshotMissingPacketCount() == 0)
}

@Test
func ignoresAudioFecPacketInsteadOfFeedingItToDecoder() async throws {
    let parser = AudioPacketParser()
    let depacketizer = SimpleAudioDepacketizer()
    let fecPacket = makeAudioPacket(
        sequenceNumber: 24,
        timestamp: 48_000,
        payloadType: AudioTransportPacket.fecPayloadType,
        payload: Data(repeating: 0xAA, count: 32)
    )

    let encoded = try await depacketizer.submit(parser.parse(fecPacket))

    #expect(encoded == nil)
}

@Test
func ignoresUnknownAudioPayloadTypeInsteadOfFailingSession() async throws {
    let parser = AudioPacketParser()
    let depacketizer = SimpleAudioDepacketizer()
    let unknownPacket = makeAudioPacket(
        sequenceNumber: 25,
        timestamp: 48_000,
        payloadType: 0,
        payload: Data(repeating: 0x55, count: 16)
    )

    let encoded = try await depacketizer.submit(parser.parse(unknownPacket))

    #expect(encoded == nil)
}

@Test
func depacketizesOutOfOrderAudioPacketWithinReorderWindow() async throws {
    let parser = AudioPacketParser()
    let depacketizer = SimpleAudioDepacketizer(reorderWindowSize: 4)

    let firstRaw = makeAudioPacket(sequenceNumber: 20, timestamp: 48_000, payload: Data([0xBB]))
    let thirdRaw = makeAudioPacket(sequenceNumber: 22, timestamp: 49_920, payload: Data([0xAA]))
    let secondRaw = makeAudioPacket(sequenceNumber: 21, timestamp: 48_960, payload: Data([0xCC]))
    let fourthRaw = makeAudioPacket(sequenceNumber: 23, timestamp: 50_880, payload: Data([0xDD]))

    let firstSubmit = try await depacketizer.submit(parser.parse(firstRaw))
    let secondSubmit = try await depacketizer.submit(parser.parse(thirdRaw))
    let thirdSubmit = try await depacketizer.submit(parser.parse(secondRaw))
    let fourthSubmit = try await depacketizer.submit(parser.parse(fourthRaw))

    #expect(firstSubmit?.payload == Data([0xBB]))
    #expect(secondSubmit == nil)
    #expect(thirdSubmit?.payload == Data([0xCC]))
    #expect(fourthSubmit?.payload == Data([0xAA]))
    #expect(await depacketizer.snapshotReorderedPacketCount() == 2)
}

@Test
func emitsAudioConcealmentPacketWhenGapExceedsWindow() async throws {
    let parser = AudioPacketParser()
    let depacketizer = SimpleAudioDepacketizer(reorderWindowSize: 2)

    let first = try await depacketizer.submit(parser.parse(
        makeAudioPacket(sequenceNumber: 20, timestamp: 48_000, payload: Data([0xBB]))
    ))
    let late = try await depacketizer.submit(parser.parse(
        makeAudioPacket(sequenceNumber: 23, timestamp: 50_880, payload: Data([0xDD]))
    ))

    #expect(first?.payload == Data([0xBB]))
    #expect(late?.isConcealment == true)
    #expect(late?.payload.isEmpty == true)
    #expect(await depacketizer.snapshotReorderedPacketCount() == 1)
    #expect(await depacketizer.snapshotMissingPacketCount() == 1)
}

@Test
func ignoresStaleAudioPacketThatFallsBehindExpectedSequence() async throws {
    let parser = AudioPacketParser()
    let depacketizer = SimpleAudioDepacketizer(reorderWindowSize: 4)

    let first = try await depacketizer.submit(parser.parse(
        makeAudioPacket(sequenceNumber: 20, timestamp: 48_000, payload: Data([0xAA]))
    ))
    let ahead = try await depacketizer.submit(parser.parse(
        makeAudioPacket(sequenceNumber: 22, timestamp: 49_920, payload: Data([0xCC]))
    ))
    let stale = try await depacketizer.submit(parser.parse(
        makeAudioPacket(sequenceNumber: 19, timestamp: 47_040, payload: Data([0x11]))
    ))
    let expected = try await depacketizer.submit(parser.parse(
        makeAudioPacket(sequenceNumber: 21, timestamp: 48_960, payload: Data([0xBB]))
    ))

    #expect(first?.payload == Data([0xAA]))
    #expect(ahead == nil)
    #expect(stale == nil)
    #expect(expected?.payload == Data([0xBB]))
    #expect(await depacketizer.snapshotMissingPacketCount() == 0)
}
