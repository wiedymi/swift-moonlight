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
func parsesVideoPacketHeaders() throws {
    let parser = VideoPacketParser()
    let packet = makeVideoPacket(
        sequenceNumber: 10,
        timestamp: 90_000,
        streamPacketIndex: 1,
        frameIndex: 7,
        flags: VideoPacketHeader.startOfFrameFlag | VideoPacketHeader.endOfFrameFlag,
        payload: Data([0x01, 0x00, 0x00] + Array(repeating: 0xAA, count: 9))
    )

    let parsed = try parser.parse(packet)

    #expect(parsed.rtp.sequenceNumber == 10)
    #expect(parsed.rtp.timestamp == 90_000)
    #expect(parsed.rtp.hasExtension == false)
    #expect(parsed.video.frameIndex == 7)
    #expect(parsed.video.isStartOfFrame)
    #expect(parsed.video.isEndOfFrame)
    #expect(parsed.hostProcessingLatencyMs == nil)
    #expect(parsed.payload.count == 12)
}

@Test
func parsesVideoPacketHeadersWithRtpExtension() throws {
    let parser = VideoPacketParser()
    let packet = makeVideoPacket(
        sequenceNumber: 12,
        timestamp: 91_000,
        streamPacketIndex: 3,
        frameIndex: 9,
        flags: VideoPacketHeader.startOfFrameFlag | VideoPacketHeader.endOfFrameFlag,
        payload: Data([0x01, 0x00, 0x00] + Array(repeating: 0xAA, count: 9)),
        rtpExtensionWords: []
    )

    let parsed = try parser.parse(packet)

    #expect(parsed.rtp.hasExtension == true)
    #expect(parsed.rtp.sequenceNumber == 12)
    #expect(parsed.video.frameIndex == 9)
    #expect(parsed.payload.count == 12)
}

@Test
func parsesVideoPacketHeadersWithZeroPayloadTypeRtpExtension() throws {
    let parser = VideoPacketParser()
    var packet = makeVideoPacket(
        sequenceNumber: 14,
        timestamp: 92_000,
        streamPacketIndex: 4,
        frameIndex: 10,
        flags: VideoPacketHeader.startOfFrameFlag | VideoPacketHeader.endOfFrameFlag,
        payload: Data([0x01, 0x00, 0x00] + Array(repeating: 0xAA, count: 9)),
        rtpExtensionWords: []
    )
    packet[1] = 0x00

    let parsed = try parser.parse(packet)

    #expect(parsed.rtp.hasExtension == true)
    #expect(parsed.rtp.packetType == 0)
    #expect(parsed.rtp.sequenceNumber == 14)
    #expect(parsed.video.frameIndex == 10)
    #expect(parsed.payload.count == 12)
}

@Test
func parsesBareVideoPacketHeadersWithoutRTPEnvelope() throws {
    let parser = VideoPacketParser()
    let packet = makeBareVideoPacket(
        streamPacketIndex: 17,
        frameIndex: 9,
        flags: VideoPacketHeader.startOfFrameFlag | VideoPacketHeader.endOfFrameFlag,
        payload: Data([0x01, 0x00, 0x00] + Array(repeating: 0xAA, count: 9))
    )

    let parsed = try parser.parse(packet)

    #expect(parsed.rtp.hasExtension == false)
    #expect(parsed.rtp.sequenceNumber == 17)
    #expect(parsed.rtp.timestamp == 9)
    #expect(parsed.video.frameIndex == 9)
    #expect(parsed.video.isStartOfFrame)
    #expect(parsed.video.isEndOfFrame)
    #expect(parsed.payload.count == 12)
}

@Test
func treatsFalsePositiveRtpLookingVideoDatagramAsBarePacket() throws {
    let parser = VideoPacketParser()
    let packet = makeBareVideoPacket(
        streamPacketIndex: 0x91,
        frameIndex: 0x56,
        flags: VideoPacketHeader.startOfFrameFlag | VideoPacketHeader.endOfFrameFlag,
        payload: Data([0x01, 0x00, 0x00] + Array(repeating: 0xAA, count: 9))
    )

    let parsed = try parser.parse(packet)

    #expect(parsed.rtp.sequenceNumber == 0x0091)
    #expect(parsed.rtp.packetType == 0)
    #expect(parsed.video.frameIndex == 0x56)
    #expect(parsed.payload.count == 12)
}

@Test
func parsesVideoPacketFecMetadata() throws {
    let parser = VideoPacketParser()
    let packet = makeVideoPacket(
        sequenceNumber: 13,
        timestamp: 91_001,
        streamPacketIndex: 3,
        frameIndex: 9,
        flags: VideoPacketHeader.startOfFrameFlag | VideoPacketHeader.endOfFrameFlag,
        multiFecBlocks: 0b0101_0000,
        fecInfo: (UInt32(6) << 22) | (UInt32(2) << 12) | (UInt32(20) << 4),
        payload: Data([0x01] + Array(repeating: 0x00, count: 7) + [0x00, 0x00, 0x00, 0x01, 0x65])
    )

    let parsed = try parser.parse(packet)

    #expect(parsed.video.fecBlockIndex == 1)
    #expect(parsed.video.fecLastBlockIndex == 1)
    #expect(parsed.video.dataShardCount == 6)
    #expect(parsed.video.fecShardIndex == 2)
    #expect(parsed.video.fecPercentage == 20)
    #expect(parsed.video.isParityShard == false)
}

@Test
func parsesSunshineHostProcessingLatencyFromVideoHeader() throws {
    let parser = VideoPacketParser()
    let packet = makeVideoPacket(
        sequenceNumber: 11,
        timestamp: 90_001,
        streamPacketIndex: 2,
        frameIndex: 8,
        flags: VideoPacketHeader.startOfFrameFlag | VideoPacketHeader.endOfFrameFlag,
        payload: Data([0x01, 0x7B, 0x00, 0, 0, 0, 0, 0, 0xAA])
    )

    let parsed = try parser.parse(packet)

    #expect(parsed.hostProcessingLatencyMs == 12.3)
}

@Test
func decryptsEncryptedVideoPacket() throws {
    let key = Data("0123456789ABCDEF".utf8)
    let context = VideoEncryptionContext(key: key)
    let plaintext = makeVideoPacket(
        sequenceNumber: 12,
        timestamp: 123_456,
        streamPacketIndex: 5,
        frameIndex: 42,
        flags: VideoPacketHeader.startOfFrameFlag | VideoPacketHeader.endOfFrameFlag,
        payload: Data([0,0,0,0,0,0,0,0, 0x11, 0x22, 0x33])
    )
    let encrypted = try MediaCrypto.encryptVideoPacket(
        plaintext,
        frameNumber: 42,
        context: context,
        iv: Data([0,1,2,3,4,5,6,7,8,9,10,11])
    )

    let decryptor = VideoPacketDecryptor()
    let header = try decryptor.parseEncryptedHeader(encrypted)
    let decrypted = try decryptor.decrypt(encrypted, context: context)

    #expect(header.frameNumber == 42)
    #expect(header.iv == Data([0,1,2,3,4,5,6,7,8,9,10,11]))
    #expect(decrypted == plaintext)
}
