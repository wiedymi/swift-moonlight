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

@Test
func depacketizesSinglePacketVideoFrame() async throws {
    let depacketizer = SimpleVideoDepacketizer(
        configuration: .init(codec: .hevc, dimensions: CGSize(width: 1920, height: 1080))
    )
    let parser = VideoPacketParser()
    let raw = makeVideoPacket(
        sequenceNumber: 1,
        timestamp: 12345,
        streamPacketIndex: 1,
        frameIndex: 99,
        flags: VideoPacketHeader.startOfFrameFlag | VideoPacketHeader.endOfFrameFlag,
        payload: Data([1,2,3,4,5,6,7,8, 0x00, 0x00, 0x00, 0x01, 0x65])
    )

    let frame = try await depacketizer.submit(parser.parse(raw))

    #expect(frame?.timestamp == 12345)
    #expect(frame?.codec == .hevc)
    #expect(frame?.payload.hexString == "0000000165")
}

@Test
func depacketizesSinglePacketVideoFrameWithLongFrameHeader() async throws {
    let depacketizer = SimpleVideoDepacketizer(
        configuration: .init(codec: .hevc, dimensions: CGSize(width: 1920, height: 1080))
    )
    let parser = VideoPacketParser()
    let longHeaderPayload = Data([0x81] + Array(repeating: 0, count: 23) + [0x00, 0x00, 0x00, 0x01, 0x65])
    let raw = makeVideoPacket(
        sequenceNumber: 2,
        timestamp: 12346,
        streamPacketIndex: 1,
        frameIndex: 100,
        flags: VideoPacketHeader.startOfFrameFlag | VideoPacketHeader.endOfFrameFlag,
        payload: longHeaderPayload,
        rtpExtensionWords: []
    )

    let frame = try await depacketizer.submit(parser.parse(raw))

    #expect(frame?.payload.hexString == "0000000165")
}

@Test
func depacketizerIgnoresParityVideoShards() async throws {
    let depacketizer = SimpleVideoDepacketizer(
        configuration: .init(codec: .hevc, dimensions: CGSize(width: 1920, height: 1080))
    )
    let parser = VideoPacketParser()
    let parityRaw = makeVideoPacket(
        sequenceNumber: 3,
        timestamp: 12347,
        streamPacketIndex: 1,
        frameIndex: 101,
        flags: 0,
        fecInfo: (UInt32(2) << 22) | (UInt32(2) << 12),
        payload: Data([0xAA, 0xBB])
    )

    let frame = try await depacketizer.submit(parser.parse(parityRaw))

    #expect(frame == nil)
}

@Test
func depacketizerWaitsForLastFecBlockBeforeEndingFrame() async throws {
    let depacketizer = SimpleVideoDepacketizer(
        configuration: .init(codec: .hevc, dimensions: CGSize(width: 1920, height: 1080))
    )
    let parser = VideoPacketParser()
    let firstBlock = try parser.parse(makeVideoPacket(
        sequenceNumber: 4,
        timestamp: 12348,
        streamPacketIndex: 1,
        frameIndex: 102,
        flags: VideoPacketHeader.startOfFrameFlag | VideoPacketHeader.endOfFrameFlag,
        multiFecBlocks: 0b0100_0000,
        payload: Data([0x01] + Array(repeating: 0x00, count: 7) + [0x00, 0x00, 0x00, 0x01])
    ))
    let secondBlock = try parser.parse(makeVideoPacket(
        sequenceNumber: 5,
        timestamp: 12348,
        streamPacketIndex: 2,
        frameIndex: 102,
        flags: VideoPacketHeader.endOfFrameFlag,
        multiFecBlocks: 0b0101_0000,
        payload: Data([0x65])
    ))

    let first = try await depacketizer.submit(firstBlock)
    let second = try await depacketizer.submit(secondBlock)

    #expect(first == nil)
    #expect(second?.payload.hexString == "0000000165")
}

@Test
func depacketizesMultiPacketVideoFrame() async throws {
    let depacketizer = SimpleVideoDepacketizer(
        configuration: .init(codec: .h264, dimensions: CGSize(width: 1280, height: 720))
    )
    let parser = VideoPacketParser()

    let start = try parser.parse(makeVideoPacket(
        sequenceNumber: 5,
        timestamp: 3000,
        streamPacketIndex: 1,
        frameIndex: 2,
        flags: VideoPacketHeader.startOfFrameFlag,
        payload: Data([0,0,0,0,0,0,0,0, 0x00, 0x00, 0x00])
    ))
    let end = try parser.parse(makeVideoPacket(
        sequenceNumber: 6,
        timestamp: 3000,
        streamPacketIndex: 2,
        frameIndex: 2,
        flags: VideoPacketHeader.endOfFrameFlag,
        payload: Data([0x01, 0x67, 0x88])
    ))

    let first = try await depacketizer.submit(start)
    let second = try await depacketizer.submit(end)

    #expect(first == nil)
    #expect(second?.payload.hexString == "000000016788")
}

@Test
func depacketizesOutOfOrderVideoFrameWithinReorderWindow() async throws {
    let depacketizer = SimpleVideoDepacketizer(
        configuration: .init(codec: .h264, dimensions: CGSize(width: 1280, height: 720), reorderWindowSize: 4)
    )
    let parser = VideoPacketParser()

    let end = try parser.parse(makeVideoPacket(
        sequenceNumber: 6,
        timestamp: 3000,
        streamPacketIndex: 2,
        frameIndex: 2,
        flags: VideoPacketHeader.endOfFrameFlag,
        payload: Data([0x01, 0x67, 0x88])
    ))
    let start = try parser.parse(makeVideoPacket(
        sequenceNumber: 5,
        timestamp: 3000,
        streamPacketIndex: 1,
        frameIndex: 2,
        flags: VideoPacketHeader.startOfFrameFlag,
        payload: Data([0,0,0,0,0,0,0,0, 0x00, 0x00, 0x00])
    ))

    let first = try await depacketizer.submit(end)
    let second = try await depacketizer.submit(start)

    #expect(first == nil)
    #expect(second?.payload.hexString == "000000016788")
    #expect(await depacketizer.snapshotReorderedPacketCount() == 0)
}

@Test
func recordsVideoSequenceDiscontinuity() async throws {
    let depacketizer = SimpleVideoDepacketizer(
        configuration: .init(codec: .hevc, dimensions: CGSize(width: 640, height: 360), reorderWindowSize: 1)
    )
    let parser = VideoPacketParser()
    let start = try parser.parse(makeVideoPacket(
        sequenceNumber: 1,
        timestamp: 1,
        streamPacketIndex: 1,
        frameIndex: 4,
        flags: VideoPacketHeader.startOfFrameFlag,
        payload: Data(repeating: 0, count: 8)
    ))
    let skipped = try parser.parse(makeVideoPacket(
        sequenceNumber: 4,
        timestamp: 1,
        streamPacketIndex: 2,
        frameIndex: 4,
        flags: VideoPacketHeader.endOfFrameFlag,
        payload: Data([0xAA])
    ))

    _ = try await depacketizer.submit(start)
    let frame = try await depacketizer.submit(skipped)

    #expect(frame == nil)
    #expect(await depacketizer.snapshotDiscontinuityCount() == 1)
    #expect(await depacketizer.snapshotMissingPacketCount() == 2)
}

@Test
func depacketizerQueuesFrameFECStatusWhenFecFrameBecomesUnrecoverable() async throws {
    let depacketizer = SimpleVideoDepacketizer(
        configuration: .init(codec: .hevc, dimensions: CGSize(width: 640, height: 360), reorderWindowSize: 1)
    )
    let parser = VideoPacketParser()
    let start = try parser.parse(makeVideoPacket(
        sequenceNumber: 10,
        timestamp: 1,
        streamPacketIndex: 1,
        frameIndex: 44,
        flags: VideoPacketHeader.startOfFrameFlag,
        fecInfo: (UInt32(3) << 22) | (UInt32(0) << 12) | (UInt32(20) << 4),
        payload: Data(repeating: 0, count: 8)
    ))
    let end = try parser.parse(makeVideoPacket(
        sequenceNumber: 12,
        timestamp: 1,
        streamPacketIndex: 3,
        frameIndex: 44,
        flags: VideoPacketHeader.endOfFrameFlag,
        fecInfo: (UInt32(3) << 22) | (UInt32(2) << 12) | (UInt32(20) << 4),
        payload: Data([0xAA])
    ))
    let futureFrame = try parser.parse(makeVideoPacket(
        sequenceNumber: 20,
        timestamp: 2,
        streamPacketIndex: 1,
        frameIndex: 45,
        flags: VideoPacketHeader.startOfFrameFlag | VideoPacketHeader.endOfFrameFlag,
        payload: Data(repeating: 0, count: 8)
    ))

    _ = try await depacketizer.submit(start)
    _ = try await depacketizer.submit(end)
    _ = try await depacketizer.submit(futureFrame)

    let statuses = await depacketizer.drainPendingFrameFECStatuses()
    #expect(statuses == [
        .init(
            frameIndex: 44,
            highestReceivedSequenceNumber: 12,
            nextContiguousSequenceNumber: 11,
            missingPacketsBeforeHighestReceived: 1,
            totalDataPackets: 3,
            totalParityPackets: 1,
            receivedDataPackets: 2,
            receivedParityPackets: 0,
            fecPercentage: 20,
            multiFecBlockIndex: 0,
            multiFecBlockCount: 1
        )
    ])
}

@Test
func depacketizerAdvancesPastParityShardsWithoutStallingFrameAssembly() async throws {
    let depacketizer = SimpleVideoDepacketizer(
        configuration: .init(codec: .h264, dimensions: CGSize(width: 1280, height: 720))
    )
    let parser = VideoPacketParser()

    let start = try parser.parse(makeVideoPacket(
        sequenceNumber: 20,
        timestamp: 4_000,
        streamPacketIndex: 1,
        frameIndex: 12,
        flags: VideoPacketHeader.startOfFrameFlag,
        fecInfo: (UInt32(2) << 22) | (UInt32(0) << 12),
        payload: Data([0, 0, 0, 0, 0, 0, 0, 0, 0x00, 0x00, 0x00])
    ))
    let parity = try parser.parse(makeVideoPacket(
        sequenceNumber: 21,
        timestamp: 4_000,
        streamPacketIndex: 2,
        frameIndex: 12,
        flags: 0,
        fecInfo: (UInt32(2) << 22) | (UInt32(2) << 12),
        payload: Data([0xFF, 0xEE])
    ))
    let end = try parser.parse(makeVideoPacket(
        sequenceNumber: 22,
        timestamp: 4_000,
        streamPacketIndex: 3,
        frameIndex: 12,
        flags: VideoPacketHeader.endOfFrameFlag,
        fecInfo: (UInt32(2) << 22) | (UInt32(1) << 12),
        payload: Data([0x01, 0x67, 0x88])
    ))

    let first = try await depacketizer.submit(start)
    let second = try await depacketizer.submit(parity)
    let frame = try await depacketizer.submit(end)

    #expect(first == nil)
    #expect(second == nil)
    #expect(frame?.payload.hexString == "000000016788")
    #expect(await depacketizer.snapshotDiscontinuityCount() == 0)
}

@Test
func depacketizerRecoversMissingFecDataShardBeforeDiscontinuity() async throws {
    let depacketizer = SimpleVideoDepacketizer(
        configuration: .init(codec: .h264, dimensions: CGSize(width: 1280, height: 720), frameHeaderSize: 0)
    )
    let parser = VideoPacketParser()
    let fecPercentage: UInt32 = 34
    let dataCount: UInt32 = 3
    let dataPackets = try [
        parser.parse(makeVideoPacket(
            sequenceNumber: 200,
            timestamp: 7_000,
            streamPacketIndex: 1,
            frameIndex: 55,
            flags: VideoPacketHeader.startOfFrameFlag,
            fecInfo: (dataCount << 22) | (UInt32(0) << 12) | (fecPercentage << 4),
            payload: Data([0xAA, 0xBB])
        )),
        parser.parse(makeVideoPacket(
            sequenceNumber: 201,
            timestamp: 7_000,
            streamPacketIndex: 2,
            frameIndex: 55,
            flags: VideoPacketHeader.containsPictureDataFlag,
            fecInfo: (dataCount << 22) | (UInt32(1) << 12) | (fecPercentage << 4),
            payload: Data([0xCC, 0xDD])
        )),
        parser.parse(makeVideoPacket(
            sequenceNumber: 202,
            timestamp: 7_000,
            streamPacketIndex: 3,
            frameIndex: 55,
            flags: VideoPacketHeader.endOfFrameFlag,
            fecInfo: (dataCount << 22) | (UInt32(2) << 12) | (fecPercentage << 4),
            payload: Data([0xEE, 0xFF])
        )),
    ]
    let fec = try ReedSolomonFEC(dataShardCount: 3, parityShardCount: 2)
    let parity = try fec.encodeParityShards(dataPackets.map(\.fecProtectedPayload))
    let parityPackets = makeVideoParityPackets(
        parity,
        baseSequenceNumber: 200,
        timestamp: 7_000,
        frameIndex: 55,
        dataShardCount: dataCount,
        fecPercentage: fecPercentage
    )

    _ = try await depacketizer.submit(dataPackets[0])
    _ = try await depacketizer.submit(dataPackets[2])
    let frame = try await depacketizer.submit(parityPackets[0])
    _ = try await depacketizer.submit(parityPackets[1])

    #expect(frame?.payload.hexString == "AABBCCDDEEFF")
    #expect(await depacketizer.snapshotDiscontinuityCount() == 0)
    #expect(await depacketizer.snapshotMissingPacketCount() == 0)
    #expect(await depacketizer.drainPendingFrameFECStatuses().isEmpty)
}

@Test
func depacketizerRecoversMissingFecStartShardBeforeFrameStart() async throws {
    let depacketizer = SimpleVideoDepacketizer(
        configuration: .init(codec: .h264, dimensions: CGSize(width: 1280, height: 720), frameHeaderSize: 0)
    )
    let parser = VideoPacketParser()
    let fecPercentage: UInt32 = 34
    let dataCount: UInt32 = 3
    let dataPackets = try [
        parser.parse(makeVideoPacket(
            sequenceNumber: 300,
            timestamp: 8_000,
            streamPacketIndex: 1,
            frameIndex: 60,
            flags: VideoPacketHeader.startOfFrameFlag,
            fecInfo: (dataCount << 22) | (UInt32(0) << 12) | (fecPercentage << 4),
            payload: Data([0xAA, 0xBB])
        )),
        parser.parse(makeVideoPacket(
            sequenceNumber: 301,
            timestamp: 8_000,
            streamPacketIndex: 2,
            frameIndex: 60,
            flags: VideoPacketHeader.containsPictureDataFlag,
            fecInfo: (dataCount << 22) | (UInt32(1) << 12) | (fecPercentage << 4),
            payload: Data([0xCC, 0xDD])
        )),
        parser.parse(makeVideoPacket(
            sequenceNumber: 302,
            timestamp: 8_000,
            streamPacketIndex: 3,
            frameIndex: 60,
            flags: VideoPacketHeader.endOfFrameFlag,
            fecInfo: (dataCount << 22) | (UInt32(2) << 12) | (fecPercentage << 4),
            payload: Data([0xEE, 0xFF])
        )),
    ]
    let fec = try ReedSolomonFEC(dataShardCount: 3, parityShardCount: 2)
    let parity = try fec.encodeParityShards(dataPackets.map(\.fecProtectedPayload))
    let parityPackets = makeVideoParityPackets(
        parity,
        baseSequenceNumber: 300,
        timestamp: 8_000,
        frameIndex: 60,
        dataShardCount: dataCount,
        fecPercentage: fecPercentage
    )

    _ = try await depacketizer.submit(dataPackets[1])
    _ = try await depacketizer.submit(dataPackets[2])
    let frame = try await depacketizer.submit(parityPackets[0])

    #expect(frame?.payload.hexString == "AABBCCDDEEFF")
    #expect(await depacketizer.snapshotDiscontinuityCount() == 0)
    #expect(await depacketizer.snapshotMissingPacketCount() == 0)
}

@Test
func videoFECBlockRecovererRecoversMissingMiddlePacket() async throws {
    let parser = VideoPacketParser()
    let fecPercentage: UInt32 = 34
    let dataCount: UInt32 = 3
    let dataPackets = try [
        parser.parse(makeVideoPacket(
            sequenceNumber: 100,
            timestamp: 5_000,
            streamPacketIndex: 1,
            frameIndex: 33,
            flags: VideoPacketHeader.startOfFrameFlag,
            fecInfo: (dataCount << 22) | (UInt32(0) << 12) | (fecPercentage << 4),
            payload: Data([0xAA, 0xBB])
        )),
        parser.parse(makeVideoPacket(
            sequenceNumber: 101,
            timestamp: 5_000,
            streamPacketIndex: 2,
            frameIndex: 33,
            flags: VideoPacketHeader.containsPictureDataFlag,
            fecInfo: (dataCount << 22) | (UInt32(1) << 12) | (fecPercentage << 4),
            payload: Data([0xCC, 0xDD])
        )),
        parser.parse(makeVideoPacket(
            sequenceNumber: 102,
            timestamp: 5_000,
            streamPacketIndex: 3,
            frameIndex: 33,
            flags: VideoPacketHeader.endOfFrameFlag,
            fecInfo: (dataCount << 22) | (UInt32(2) << 12) | (fecPercentage << 4),
            payload: Data([0xEE, 0xFF])
        )),
    ]
    let fec = try ReedSolomonFEC(dataShardCount: 3, parityShardCount: 2)
    let parity = try fec.encodeParityShards(dataPackets.map(\.fecProtectedPayload))
    let parityPackets = makeVideoParityPackets(
        parity,
        baseSequenceNumber: 100,
        timestamp: 5_000,
        frameIndex: 33,
        dataShardCount: dataCount,
        fecPercentage: fecPercentage
    )

    let recovered = try VideoFECBlockRecoverer().recoverMissingDataPackets(from: [
        dataPackets[0],
        dataPackets[2],
        parityPackets[0],
        parityPackets[1],
    ])

    #expect(recovered.count == 1)
    #expect(recovered[0].rtp.sequenceNumber == 101)
    #expect(recovered[0].video == dataPackets[1].video)
    #expect(recovered[0].payload == dataPackets[1].payload)

    let depacketizer = SimpleVideoDepacketizer(
        configuration: .init(codec: .h264, dimensions: CGSize(width: 1280, height: 720), frameHeaderSize: 0)
    )
    _ = try await depacketizer.submit(dataPackets[0])
    _ = try await depacketizer.submit(recovered[0])
    let frame = try await depacketizer.submit(dataPackets[2])

    #expect(frame?.payload.hexString == "AABBCCDDEEFF")
}

@Test
func videoFECBlockRecovererRejectsCorruptRecoveredHeader() throws {
    let parser = VideoPacketParser()
    let fecPercentage: UInt32 = 34
    let dataCount: UInt32 = 3
    let dataPackets = try [
        parser.parse(makeVideoPacket(
            sequenceNumber: 110,
            timestamp: 6_000,
            streamPacketIndex: 1,
            frameIndex: 34,
            flags: VideoPacketHeader.startOfFrameFlag,
            fecInfo: (dataCount << 22) | (UInt32(0) << 12) | (fecPercentage << 4),
            payload: Data([0xAA, 0xBB])
        )),
        parser.parse(makeVideoPacket(
            sequenceNumber: 111,
            timestamp: 6_000,
            streamPacketIndex: 2,
            frameIndex: 34,
            flags: 0,
            fecInfo: (dataCount << 22) | (UInt32(1) << 12) | (fecPercentage << 4),
            payload: Data([0xCC, 0xDD])
        )),
        parser.parse(makeVideoPacket(
            sequenceNumber: 112,
            timestamp: 6_000,
            streamPacketIndex: 3,
            frameIndex: 34,
            flags: VideoPacketHeader.endOfFrameFlag,
            fecInfo: (dataCount << 22) | (UInt32(2) << 12) | (fecPercentage << 4),
            payload: Data([0xEE, 0xFF])
        )),
    ]
    let fec = try ReedSolomonFEC(dataShardCount: 3, parityShardCount: 2)
    let parity = try fec.encodeParityShards(dataPackets.map(\.fecProtectedPayload))
    let parityPackets = makeVideoParityPackets(
        parity,
        baseSequenceNumber: 110,
        timestamp: 6_000,
        frameIndex: 34,
        dataShardCount: dataCount,
        fecPercentage: fecPercentage
    )

    #expect(throws: VideoFECRecoveryError.invalidRecoveredPacket) {
        _ = try VideoFECBlockRecoverer().recoverMissingDataPackets(from: [
            dataPackets[0],
            dataPackets[2],
            parityPackets[0],
            parityPackets[1],
        ])
    }
}

@Test
func depacketizerSkipsPacketsWithInvalidHeaderFlagsWhileAdvancingSequence() async throws {
    let depacketizer = SimpleVideoDepacketizer(
        configuration: .init(codec: .h264, dimensions: CGSize(width: 1280, height: 720))
    )
    let parser = VideoPacketParser()

    let start = try parser.parse(makeVideoPacket(
        sequenceNumber: 30,
        timestamp: 5_000,
        streamPacketIndex: 1,
        frameIndex: 20,
        flags: VideoPacketHeader.startOfFrameFlag,
        payload: Data([0, 0, 0, 0, 0, 0, 0, 0, 0x00, 0x00, 0x00])
    ))
    let invalid = try parser.parse(makeVideoPacket(
        sequenceNumber: 31,
        timestamp: 5_000,
        streamPacketIndex: 2,
        frameIndex: 20,
        flags: 0x9F,
        payload: Data([0xDE, 0xAD, 0xBE, 0xEF])
    ))
    let end = try parser.parse(makeVideoPacket(
        sequenceNumber: 32,
        timestamp: 5_000,
        streamPacketIndex: 3,
        frameIndex: 20,
        flags: VideoPacketHeader.endOfFrameFlag,
        payload: Data([0x01, 0x67, 0x88])
    ))

    let first = try await depacketizer.submit(start)
    let second = try await depacketizer.submit(invalid)
    let frame = try await depacketizer.submit(end)

    #expect(first == nil)
    #expect(second == nil)
    #expect(frame?.payload.hexString == "000000016788")
    #expect(await depacketizer.snapshotDiscontinuityCount() == 0)
}

@Test
func ignoresStaleVideoPacketThatFallsBehindExpectedSequence() async throws {
    let depacketizer = SimpleVideoDepacketizer(
        configuration: .init(codec: .hevc, dimensions: CGSize(width: 640, height: 360), reorderWindowSize: 4)
    )
    let parser = VideoPacketParser()

    let start = try parser.parse(makeVideoPacket(
        sequenceNumber: 100,
        timestamp: 5_000,
        streamPacketIndex: 1,
        frameIndex: 8,
        flags: VideoPacketHeader.startOfFrameFlag,
        payload: Data([0, 0, 0, 0, 0, 0, 0, 0, 0x00, 0x00])
    ))
    let end = try parser.parse(makeVideoPacket(
        sequenceNumber: 102,
        timestamp: 5_000,
        streamPacketIndex: 3,
        frameIndex: 8,
        flags: VideoPacketHeader.endOfFrameFlag,
        payload: Data([0x01, 0x65])
    ))
    let stale = try parser.parse(makeVideoPacket(
        sequenceNumber: 99,
        timestamp: 4_000,
        streamPacketIndex: 7,
        frameIndex: 7,
        flags: VideoPacketHeader.endOfFrameFlag,
        payload: Data([0xDE, 0xAD])
    ))
    let middle = try parser.parse(makeVideoPacket(
        sequenceNumber: 101,
        timestamp: 5_000,
        streamPacketIndex: 2,
        frameIndex: 8,
        flags: 0,
        payload: Data([0x00, 0x00])
    ))

    let first = try await depacketizer.submit(start)
    let second = try await depacketizer.submit(end)
    let third = try await depacketizer.submit(stale)
    let frame = try await depacketizer.submit(middle)

    #expect(first == nil)
    #expect(second == nil)
    #expect(third == nil)
    #expect(frame?.payload.hexString == "000000000165")
    #expect(await depacketizer.snapshotReorderedPacketCount() == 1)
    #expect(await depacketizer.snapshotDiscontinuityCount() == 0)
    #expect(await depacketizer.snapshotMissingPacketCount() == 0)
}

@Test
func forwardVideoGapDoesNotCountAsReorderedPacket() async throws {
    let depacketizer = SimpleVideoDepacketizer(
        configuration: .init(codec: .hevc, dimensions: CGSize(width: 640, height: 360), reorderWindowSize: 4)
    )
    let parser = VideoPacketParser()

    let start = try parser.parse(makeVideoPacket(
        sequenceNumber: 10,
        timestamp: 5_000,
        streamPacketIndex: 1,
        frameIndex: 8,
        flags: VideoPacketHeader.startOfFrameFlag,
        payload: Data(repeating: 0, count: 8)
    ))
    let future = try parser.parse(makeVideoPacket(
        sequenceNumber: 12,
        timestamp: 5_000,
        streamPacketIndex: 3,
        frameIndex: 8,
        flags: VideoPacketHeader.endOfFrameFlag,
        payload: Data([0x01])
    ))

    _ = try await depacketizer.submit(start)
    _ = try await depacketizer.submit(future)

    #expect(await depacketizer.snapshotReorderedPacketCount() == 0)
}

@Test
func discontinuityMissingCountUsesCurrentFecBlockHoles() async throws {
    let depacketizer = SimpleVideoDepacketizer(
        configuration: .init(codec: .hevc, dimensions: CGSize(width: 640, height: 360), reorderWindowSize: 1)
    )
    let parser = VideoPacketParser()
    let fecInfoBase = (UInt32(3) << 22) | (UInt32(20) << 4)

    let start = try parser.parse(makeVideoPacket(
        sequenceNumber: 10,
        timestamp: 5_000,
        streamPacketIndex: 1,
        frameIndex: 8,
        flags: VideoPacketHeader.startOfFrameFlag,
        fecInfo: fecInfoBase | (UInt32(0) << 12),
        payload: Data(repeating: 0, count: 8)
    ))
    let sameBlockAfterHole = try parser.parse(makeVideoPacket(
        sequenceNumber: 12,
        timestamp: 5_000,
        streamPacketIndex: 3,
        frameIndex: 8,
        flags: VideoPacketHeader.endOfFrameFlag,
        fecInfo: fecInfoBase | (UInt32(2) << 12),
        payload: Data([0x01])
    ))
    let futureFrame = try parser.parse(makeVideoPacket(
        sequenceNumber: 80,
        timestamp: 6_000,
        streamPacketIndex: 1,
        frameIndex: 9,
        flags: VideoPacketHeader.startOfFrameFlag,
        fecInfo: fecInfoBase | (UInt32(0) << 12),
        payload: Data(repeating: 0, count: 8)
    ))

    _ = try await depacketizer.submit(start)
    _ = try await depacketizer.submit(sameBlockAfterHole)
    _ = try await depacketizer.submit(futureFrame)

    #expect(await depacketizer.snapshotDiscontinuityCount() == 1)
    #expect(await depacketizer.snapshotMissingPacketCount() == 1)
}

@Test
func interFrameSequenceJumpDoesNotInflateMissingPacketCount() async throws {
    let depacketizer = SimpleVideoDepacketizer(
        configuration: .init(codec: .hevc, dimensions: CGSize(width: 640, height: 360), reorderWindowSize: 1)
    )
    let parser = VideoPacketParser()

    let firstFrame = try parser.parse(makeVideoPacket(
        sequenceNumber: 10,
        timestamp: 5_000,
        streamPacketIndex: 1,
        frameIndex: 8,
        flags: VideoPacketHeader.startOfFrameFlag | VideoPacketHeader.endOfFrameFlag,
        payload: Data(repeating: 0, count: 8)
    ))
    let laterFrame = try parser.parse(makeVideoPacket(
        sequenceNumber: 80,
        timestamp: 6_000,
        streamPacketIndex: 1,
        frameIndex: 20,
        flags: VideoPacketHeader.startOfFrameFlag | VideoPacketHeader.endOfFrameFlag,
        payload: Data(repeating: 0, count: 8)
    ))

    _ = try await depacketizer.submit(firstFrame)
    _ = try await depacketizer.submit(laterFrame)

    #expect(await depacketizer.snapshotDiscontinuityCount() == 1)
    #expect(await depacketizer.snapshotMissingPacketCount() == 0)
}

@Test
func postFrameNonStartFecGapCountsOnlyNewBlockHoles() async throws {
    let depacketizer = SimpleVideoDepacketizer(
        configuration: .init(codec: .hevc, dimensions: CGSize(width: 640, height: 360), reorderWindowSize: 1)
    )
    let parser = VideoPacketParser()

    let completedFrame = try parser.parse(makeVideoPacket(
        sequenceNumber: 10,
        timestamp: 5_000,
        streamPacketIndex: 1,
        frameIndex: 8,
        flags: VideoPacketHeader.startOfFrameFlag | VideoPacketHeader.endOfFrameFlag,
        payload: Data(repeating: 0, count: 8)
    ))
    let laterNonStartShard = try parser.parse(makeVideoPacket(
        sequenceNumber: 80,
        timestamp: 6_000,
        streamPacketIndex: 6,
        frameIndex: 20,
        flags: VideoPacketHeader.containsPictureDataFlag,
        fecInfo: (UInt32(10) << 22) | (UInt32(5) << 12) | (UInt32(20) << 4),
        payload: Data([0x01])
    ))

    _ = try await depacketizer.submit(completedFrame)
    _ = try await depacketizer.submit(laterNonStartShard)

    #expect(await depacketizer.snapshotDiscontinuityCount() == 1)
    #expect(await depacketizer.snapshotMissingPacketCount() == 5)
}

@Test
func depacketizerAdvancesAcrossPostFrameParityGapWithoutStalling() async throws {
    let depacketizer = SimpleVideoDepacketizer(
        configuration: .init(codec: .hevc, dimensions: CGSize(width: 640, height: 360), reorderWindowSize: 64)
    )
    let parser = VideoPacketParser()

    let firstFrame = try parser.parse(makeVideoPacket(
        sequenceNumber: 100,
        timestamp: 5_000,
        streamPacketIndex: 1,
        frameIndex: 8,
        flags: VideoPacketHeader.startOfFrameFlag | VideoPacketHeader.endOfFrameFlag,
        payload: Data(repeating: 0, count: 8) + Data([0xAA])
    ))
    let nextFrame = try parser.parse(makeVideoPacket(
        sequenceNumber: 104,
        timestamp: 6_000,
        streamPacketIndex: 1,
        frameIndex: 9,
        flags: VideoPacketHeader.startOfFrameFlag | VideoPacketHeader.endOfFrameFlag,
        payload: Data(repeating: 0, count: 8) + Data([0xBB])
    ))

    let first = try await depacketizer.submit(firstFrame)
    let second = try await depacketizer.submit(nextFrame)

    #expect(first?.payload == Data([0xAA]))
    #expect(second?.payload == Data([0xBB]))
    #expect(await depacketizer.snapshotDiscontinuityCount() == 0)
    #expect(await depacketizer.snapshotMissingPacketCount() == 0)
}

@Test
func depacketizerReportsInterFrameStartGapWithoutWaitingForReorderWindow() async throws {
    let depacketizer = SimpleVideoDepacketizer(
        configuration: .init(codec: .hevc, dimensions: CGSize(width: 640, height: 360), reorderWindowSize: 64)
    )
    let parser = VideoPacketParser()

    let firstFrame = try parser.parse(makeVideoPacket(
        sequenceNumber: 200,
        timestamp: 5_000,
        streamPacketIndex: 1,
        frameIndex: 20,
        flags: VideoPacketHeader.startOfFrameFlag | VideoPacketHeader.endOfFrameFlag,
        payload: Data(repeating: 0, count: 8) + Data([0xAA])
    ))
    let laterFrame = try parser.parse(makeVideoPacket(
        sequenceNumber: 230,
        timestamp: 6_000,
        streamPacketIndex: 1,
        frameIndex: 27,
        flags: VideoPacketHeader.startOfFrameFlag | VideoPacketHeader.endOfFrameFlag,
        payload: Data(repeating: 0, count: 8) + Data([0xBB])
    ))

    let first = try await depacketizer.submit(firstFrame)
    let second = try await depacketizer.submit(laterFrame)

    #expect(first?.payload == Data([0xAA]))
    #expect(second?.payload == Data([0xBB]))
    #expect(await depacketizer.snapshotDiscontinuityCount() == 1)
    #expect(await depacketizer.snapshotMissingPacketCount() == 0)
}

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

@Test
func videoIngestServiceFeedsPipeline() async throws {
    let source = FixtureMediaPacketSource(packets: [
        makeVideoPacket(
            sequenceNumber: 1,
            timestamp: 111,
            streamPacketIndex: 1,
            frameIndex: 10,
            flags: VideoPacketHeader.startOfFrameFlag | VideoPacketHeader.endOfFrameFlag,
            payload: Data([0,0,0,0,0,0,0,0, 0x99, 0x88])
        )
    ])
    let pipeline = MediaPipeline()
    let decoder = RecordingVideoDecoder(decodeOutputs: [[
        DecodedVideoFrame(timestamp: 111, dimensions: CGSize(width: 800, height: 600), bytes: Data([0x01]))
    ]])
    let renderer = RecordingRenderer()
    try await pipeline.attachVideoDecoder(decoder)
    try await pipeline.attachRenderer(renderer)
    try await pipeline.configureVideo(format: .init(codec: .hevc, dimensions: CGSize(width: 800, height: 600)))

    let service = VideoIngestService(
        source: source,
        depacketizer: SimpleVideoDepacketizer(configuration: .init(codec: .hevc, dimensions: CGSize(width: 800, height: 600))),
        pipeline: pipeline
    )

    let frame = try await service.receiveNextFrame()
    let rendered = await renderer.recordedFrames()

    #expect(frame?.payload.hexString == "9988")
    #expect(rendered.count == 1)
}

@Test
func encryptedVideoIngestServiceFeedsPipeline() async throws {
    let key = Data("0123456789ABCDEF".utf8)
    let encryptionContext = VideoEncryptionContext(key: key)
    let plaintext = makeVideoPacket(
        sequenceNumber: 1,
        timestamp: 111,
        streamPacketIndex: 1,
        frameIndex: 10,
        flags: VideoPacketHeader.startOfFrameFlag | VideoPacketHeader.endOfFrameFlag,
        payload: Data([0,0,0,0,0,0,0,0, 0x99, 0x88])
    )
    let encrypted = try MediaCrypto.encryptVideoPacket(
        plaintext,
        frameNumber: 10,
        context: encryptionContext,
        iv: Data([0,1,2,3,4,5,6,7,8,9,10,11])
    )

    let source = FixtureMediaPacketSource(packets: [encrypted])
    let pipeline = MediaPipeline()
    let decoder = RecordingVideoDecoder(decodeOutputs: [[
        DecodedVideoFrame(timestamp: 111, dimensions: CGSize(width: 800, height: 600), bytes: Data([0x01]))
    ]])
    let renderer = RecordingRenderer()
    try await pipeline.attachVideoDecoder(decoder)
    try await pipeline.attachRenderer(renderer)
    try await pipeline.configureVideo(format: .init(codec: .hevc, dimensions: CGSize(width: 800, height: 600)))

    let service = VideoIngestService(
        source: source,
        decryptor: VideoPacketDecryptor(),
        encryptionContext: encryptionContext,
        depacketizer: SimpleVideoDepacketizer(configuration: .init(codec: .hevc, dimensions: CGSize(width: 800, height: 600))),
        pipeline: pipeline
    )

    let frame = try await service.receiveNextFrame()
    let rendered = await renderer.recordedFrames()

    #expect(frame?.payload.hexString == "9988")
    #expect(rendered.count == 1)
}

@Test
func bareVideoIngestServiceUsesArrivalOrderForFrameAssembly() async throws {
    let source = FixtureMediaPacketSource(packets: [
        makeBareVideoPacket(
            streamPacketIndex: 0x100,
            frameIndex: 10,
            flags: VideoPacketHeader.startOfFrameFlag,
            payload: Data([0,0,0,0,0,0,0,0, 0x99])
        ),
        makeBareVideoPacket(
            streamPacketIndex: 0x500,
            frameIndex: 10,
            flags: VideoPacketHeader.endOfFrameFlag,
            payload: Data([0x88])
        )
    ])
    let pipeline = MediaPipeline()
    let decoder = RecordingVideoDecoder(decodeOutputs: [[
        DecodedVideoFrame(timestamp: 10, dimensions: CGSize(width: 800, height: 600), bytes: Data([0x01]))
    ]])
    let renderer = RecordingRenderer()
    try await pipeline.attachVideoDecoder(decoder)
    try await pipeline.attachRenderer(renderer)
    try await pipeline.configureVideo(format: .init(codec: .hevc, dimensions: CGSize(width: 800, height: 600)))

    let service = VideoIngestService(
        source: source,
        depacketizer: SimpleVideoDepacketizer(configuration: .init(codec: .hevc, dimensions: CGSize(width: 800, height: 600))),
        pipeline: pipeline
    )

    let first = try await service.receiveNextFrame()
    let second = try await service.receiveNextFrame()
    let rendered = await renderer.recordedFrames()

    #expect(first?.payload.hexString == "9988")
    #expect(second == nil)
    #expect(rendered.count == 1)
}

@Test
func videoIngestServiceRecordsBoundedPacketTrace() async throws {
    let source = FixtureMediaPacketSource(packets: [
        makeVideoPacket(
            sequenceNumber: 30,
            timestamp: 10_000,
            streamPacketIndex: 1,
            frameIndex: 10,
            flags: VideoPacketHeader.startOfFrameFlag | VideoPacketHeader.endOfFrameFlag,
            fecInfo: (UInt32(1) << 22) | (UInt32(0) << 12) | (UInt32(20) << 4),
            payload: Data([0,0,0,0,0,0,0,0, 0x99])
        ),
        makeVideoPacket(
            sequenceNumber: 31,
            timestamp: 10_001,
            streamPacketIndex: 1,
            frameIndex: 11,
            flags: VideoPacketHeader.startOfFrameFlag | VideoPacketHeader.endOfFrameFlag,
            payload: Data([0,0,0,0,0,0,0,0, 0x88])
        ),
    ])
    let pipeline = MediaPipeline()
    let decoder = RecordingVideoDecoder(decodeOutputs: [
        [DecodedVideoFrame(timestamp: 10_000, dimensions: CGSize(width: 800, height: 600), bytes: Data([0x01]))],
        [DecodedVideoFrame(timestamp: 10_001, dimensions: CGSize(width: 800, height: 600), bytes: Data([0x02]))],
    ])
    try await pipeline.attachVideoDecoder(decoder)
    try await pipeline.configureVideo(format: .init(codec: .hevc, dimensions: CGSize(width: 800, height: 600)))

    let service = VideoIngestService(
        source: source,
        depacketizer: SimpleVideoDepacketizer(configuration: .init(codec: .hevc, dimensions: CGSize(width: 800, height: 600))),
        pipeline: pipeline,
        packetTraceLimit: 1
    )

    _ = try await service.receiveNextFrame()
    _ = try await service.receiveNextFrame()
    let trace = await service.snapshotPacketTrace()

    #expect(trace.count == 1)
    #expect(trace[0].observedPacketIndex == 2)
    #expect(trace[0].sequenceNumber == 31)
    #expect(trace[0].frameIndex == 11)
    #expect(!trace[0].usedSyntheticSequenceNumber)
}

@Test
func videoIngestServiceCanSubmitPipelineAsynchronously() async throws {
    let source = FixtureMediaPacketSource(packets: [
        makeVideoPacket(
            sequenceNumber: 40,
            timestamp: 10_000,
            streamPacketIndex: 1,
            frameIndex: 10,
            flags: VideoPacketHeader.startOfFrameFlag | VideoPacketHeader.endOfFrameFlag,
            payload: Data([0,0,0,0,0,0,0,0, 0x99])
        ),
        makeVideoPacket(
            sequenceNumber: 41,
            timestamp: 10_001,
            streamPacketIndex: 1,
            frameIndex: 11,
            flags: VideoPacketHeader.startOfFrameFlag | VideoPacketHeader.endOfFrameFlag,
            payload: Data([0,0,0,0,0,0,0,0, 0x88])
        ),
    ])
    let pipeline = MediaPipeline()
    let decoder = BlockingFirstVideoDecoder(decodeOutputs: [
        [DecodedVideoFrame(timestamp: 10_000, dimensions: CGSize(width: 800, height: 600), bytes: Data([0x01]))],
        [DecodedVideoFrame(timestamp: 10_001, dimensions: CGSize(width: 800, height: 600), bytes: Data([0x02]))],
    ])
    let renderer = RecordingRenderer()
    try await pipeline.attachVideoDecoder(decoder)
    try await pipeline.attachRenderer(renderer)
    try await pipeline.configureVideo(format: .init(codec: .hevc, dimensions: CGSize(width: 800, height: 600)))

    let service = VideoIngestService(
        source: source,
        depacketizer: SimpleVideoDepacketizer(configuration: .init(codec: .hevc, dimensions: CGSize(width: 800, height: 600))),
        pipeline: pipeline,
        pipelineSubmissionMode: .asynchronous(maxInFlightFrames: 2)
    )

    let first = try await service.receiveNextFrame()
    let second = try await service.receiveNextFrame()
    let renderedBeforeRelease = await renderer.recordedFrames()

    #expect(first?.payload.hexString == "99")
    #expect(second?.payload.hexString == "88")
    #expect(await service.snapshotObservedPacketCount() == 2)
    #expect(renderedBeforeRelease.isEmpty)

    await decoder.releaseFirstDecode()
    let end = try await service.receiveNextFrame()
    let renderedAfterRelease = await renderer.recordedFrames()

    #expect(end == nil)
    #expect(renderedAfterRelease.count == 2)
    #expect(renderedAfterRelease.map(\.timestamp) == [10_000, 10_001])
}

@Test
func videoIngestServiceIgnoresLeadingNonStartPacketsUntilFirstFrameBoundary() async throws {
    let source = FixtureMediaPacketSource(packets: [
        makeVideoPacket(
            sequenceNumber: 40,
            timestamp: 10_000,
            streamPacketIndex: 1,
            frameIndex: 9,
            flags: 0,
            payload: Data([0xAA])
        ),
        makeVideoPacket(
            sequenceNumber: 41,
            timestamp: 10_000,
            streamPacketIndex: 2,
            frameIndex: 9,
            flags: VideoPacketHeader.endOfFrameFlag,
            payload: Data([0xBB])
        ),
        makeVideoPacket(
            sequenceNumber: 42,
            timestamp: 10_001,
            streamPacketIndex: 3,
            frameIndex: 10,
            flags: VideoPacketHeader.startOfFrameFlag | VideoPacketHeader.endOfFrameFlag,
            payload: Data([0,0,0,0,0,0,0,0, 0x99, 0x88])
        )
    ])
    let pipeline = MediaPipeline()
    let decoder = RecordingVideoDecoder(decodeOutputs: [[
        DecodedVideoFrame(timestamp: 10_001, dimensions: CGSize(width: 800, height: 600), bytes: Data([0x01]))
    ]])
    let renderer = RecordingRenderer()
    try await pipeline.attachVideoDecoder(decoder)
    try await pipeline.attachRenderer(renderer)
    try await pipeline.configureVideo(format: .init(codec: .hevc, dimensions: CGSize(width: 800, height: 600)))

    let service = VideoIngestService(
        source: source,
        depacketizer: SimpleVideoDepacketizer(configuration: .init(codec: .hevc, dimensions: CGSize(width: 800, height: 600), reorderWindowSize: 1)),
        pipeline: pipeline
    )

    let frame = try await service.receiveNextFrame()
    let rendered = await renderer.recordedFrames()

    #expect(frame?.payload.hexString == "9988")
    #expect(rendered.count == 1)
    #expect(await service.snapshotObservedPacketCount() == 3)
}

@Test
func audioIngestServiceFeedsPipeline() async throws {
    let source = FixtureMediaPacketSource(packets: [
        makeAudioPacket(sequenceNumber: 4, timestamp: 960, payload: Data([0xAA, 0xBB]))
    ])
    let pipeline = MediaPipeline()
    let sink = RecordingAudioSink()
    try await pipeline.attachAudioDecoder(RecordingAudioDecoder(outputs: [
        PCMBuffer(sampleRate: 48_000, channelCount: 2, frameCount: 960, bytesPerFrame: 4, data: Data([0x01, 0x02]))
    ]))
    try await pipeline.attachAudioSink(sink)
    try await pipeline.configureAudio(format: .init(sampleRate: 48_000, channelCount: 2))

    let service = AudioIngestService(source: source, pipeline: pipeline)
    let packet = try await service.receiveNextPacket()
    let played = await sink.recordedBuffers()

    #expect(packet?.payload.hexString == "AABB")
    #expect(played.count == 1)
}

@Test
func encryptedAudioIngestServiceFeedsPipeline() async throws {
    let key = Data("0123456789ABCDEF".utf8)
    let encryptionContext = AudioEncryptionContext(key: key, avRiKeyID: 0x1020_3040)
    let plaintext = makeAudioPacket(sequenceNumber: 4, timestamp: 960, payload: Data([0xAA, 0xBB]))
    let encrypted = try MediaCrypto.encryptAudioPacket(
        rtpHeader: Data(plaintext.prefix(RTPHeader.fixedSize)),
        payload: Data(plaintext.dropFirst(RTPHeader.fixedSize)),
        context: encryptionContext,
        sequenceNumber: 4
    )

    let source = FixtureMediaPacketSource(packets: [encrypted])
    let pipeline = MediaPipeline()
    let sink = RecordingAudioSink()
    try await pipeline.attachAudioDecoder(RecordingAudioDecoder(outputs: [
        PCMBuffer(sampleRate: 48_000, channelCount: 2, frameCount: 960, bytesPerFrame: 4, data: Data([0x01, 0x02]))
    ]))
    try await pipeline.attachAudioSink(sink)
    try await pipeline.configureAudio(format: .init(sampleRate: 48_000, channelCount: 2))

    let service = AudioIngestService(
        source: source,
        decryptor: AudioPacketDecryptor(),
        encryptionContext: encryptionContext,
        pipeline: pipeline
    )
    let packet = try await service.receiveNextPacket()
    let played = await sink.recordedBuffers()

    #expect(packet?.payload.hexString == "AABB")
    #expect(played.count == 1)
}

@Test
func audioIngestServiceSkipsMalformedNonRtpDatagram() async throws {
    let source = FixtureMediaPacketSource(packets: [
        Data([0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
              0x00, 0x00, 0x00, 0x56, 0x78, 0x1C, 0x7A, 0xBF]),
        makeAudioPacket(sequenceNumber: 4, timestamp: 960, payload: Data([0xAA, 0xBB]))
    ])
    let pipeline = MediaPipeline()
    let sink = RecordingAudioSink()
    try await pipeline.attachAudioDecoder(RecordingAudioDecoder(outputs: [
        PCMBuffer(sampleRate: 48_000, channelCount: 2, frameCount: 960, bytesPerFrame: 4, data: Data([0x01, 0x02]))
    ]))
    try await pipeline.attachAudioSink(sink)
    try await pipeline.configureAudio(format: .init(sampleRate: 48_000, channelCount: 2))

    let service = AudioIngestService(source: source, pipeline: pipeline)
    let packet = try await service.receiveNextPacket()
    let played = await sink.recordedBuffers()

    #expect(packet?.payload.hexString == "AABB")
    #expect(played.count == 1)
    #expect(await service.snapshotObservedPacketCount() == 2)
}

@Test
func audioIngestServiceTracksConcealmentPackets() async throws {
    let source = FixtureMediaPacketSource(packets: [
        makeAudioPacket(sequenceNumber: 4, timestamp: 960, payload: Data([0xAA])),
        makeAudioPacket(sequenceNumber: 7, timestamp: 3_840, payload: Data([0xBB]))
    ])
    let pipeline = MediaPipeline()
    let sink = RecordingAudioSink()
    try await pipeline.attachAudioDecoder(RecordingAudioDecoder(outputs: [
        PCMBuffer(sampleRate: 48_000, channelCount: 2, frameCount: 960, bytesPerFrame: 4, data: Data([0x01, 0x02])),
        PCMBuffer(sampleRate: 48_000, channelCount: 2, frameCount: 960, bytesPerFrame: 4, data: Data([0x03, 0x04]))
    ]))
    try await pipeline.attachAudioSink(sink)
    try await pipeline.configureAudio(format: .init(sampleRate: 48_000, channelCount: 2))

    let service = AudioIngestService(
        source: source,
        depacketizer: SimpleAudioDepacketizer(reorderWindowSize: 2),
        pipeline: pipeline
    )

    _ = try await service.receiveNextPacket()
    let second = try await service.receiveNextPacket()
    let concealments = await service.snapshotConcealedPacketCount()

    #expect(second?.isConcealment == true)
    #expect(concealments == 1)
    #expect(await service.snapshotReorderedPacketCount() == 1)
    #expect(await service.snapshotMissingPacketCount() == 1)
}

@Test
func udpPacketSourceReceivesLoopbackDatagram() async throws {
    let source = try UDPPacketSource(port: 0)
    defer {
        Task { await source.stop() }
    }

    let port = await source.localPort()
    try sendUDPDatagram(Data([0xDE, 0xAD, 0xBE, 0xEF]), to: port)

    let received = try await source.receivePacket()

    #expect(received == Data([0xDE, 0xAD, 0xBE, 0xEF]))
}

private actor BlockingFirstVideoDecoder: VideoDecoder {
    private var configuredFormats: [VideoFormat] = []
    private var decodedInputs: [EncodedVideoFrame] = []
    private var decodeOutputs: [[DecodedVideoFrame]]
    private var shouldBlockFirstDecode = true
    private var releaseRequested = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(decodeOutputs: [[DecodedVideoFrame]]) {
        self.decodeOutputs = decodeOutputs
    }

    func configure(format: VideoFormat) async throws {
        configuredFormats.append(format)
    }

    func decode(_ frame: EncodedVideoFrame) async throws -> [DecodedVideoFrame] {
        decodedInputs.append(frame)
        if shouldBlockFirstDecode {
            shouldBlockFirstDecode = false
            if !releaseRequested {
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                }
            }
        }

        guard !decodeOutputs.isEmpty else {
            return []
        }
        return decodeOutputs.removeFirst()
    }

    func flush() async throws -> [DecodedVideoFrame] {
        []
    }

    func releaseFirstDecode() {
        releaseRequested = true
        continuation?.resume()
        continuation = nil
    }
}

private func makeVideoPacket(
    sequenceNumber: UInt16,
    timestamp: UInt32,
    streamPacketIndex: UInt32,
    frameIndex: UInt32,
    flags: UInt8,
    extraFlags: UInt8 = 0,
    multiFecFlags: UInt8 = 0,
    multiFecBlocks: UInt8 = 0,
    fecInfo: UInt32 = 0,
    payload: Data,
    rtpExtensionWords: [UInt32]? = nil
) -> Data {
    var data = Data()
    data.append(rtpExtensionWords == nil ? 0x80 : 0x90)
    data.append(0x60)
    data.append(UInt8(truncatingIfNeeded: sequenceNumber >> 8))
    data.append(UInt8(truncatingIfNeeded: sequenceNumber))
    data.append(contentsOf: [
        UInt8(truncatingIfNeeded: timestamp >> 24),
        UInt8(truncatingIfNeeded: timestamp >> 16),
        UInt8(truncatingIfNeeded: timestamp >> 8),
        UInt8(truncatingIfNeeded: timestamp)
    ])
    data.append(contentsOf: [0,0,0,1])
    if let rtpExtensionWords {
        data.append(contentsOf: [0xBE, 0xDE])
        let length = UInt16(rtpExtensionWords.count)
        data.append(UInt8(truncatingIfNeeded: length >> 8))
        data.append(UInt8(truncatingIfNeeded: length))
        for word in rtpExtensionWords {
            data.append(contentsOf: [
                UInt8(truncatingIfNeeded: word >> 24),
                UInt8(truncatingIfNeeded: word >> 16),
                UInt8(truncatingIfNeeded: word >> 8),
                UInt8(truncatingIfNeeded: word)
            ])
        }
    }
    data.append(contentsOf: [
        UInt8(truncatingIfNeeded: streamPacketIndex),
        UInt8(truncatingIfNeeded: streamPacketIndex >> 8),
        UInt8(truncatingIfNeeded: streamPacketIndex >> 16),
        UInt8(truncatingIfNeeded: streamPacketIndex >> 24),
        UInt8(truncatingIfNeeded: frameIndex),
        UInt8(truncatingIfNeeded: frameIndex >> 8),
        UInt8(truncatingIfNeeded: frameIndex >> 16),
        UInt8(truncatingIfNeeded: frameIndex >> 24),
        flags,
        extraFlags,
        multiFecFlags,
        multiFecBlocks,
        UInt8(truncatingIfNeeded: fecInfo),
        UInt8(truncatingIfNeeded: fecInfo >> 8),
        UInt8(truncatingIfNeeded: fecInfo >> 16),
        UInt8(truncatingIfNeeded: fecInfo >> 24)
    ])
    data.append(payload)
    return data
}

private func makeBareVideoPacket(
    streamPacketIndex: UInt32,
    frameIndex: UInt32,
    flags: UInt8,
    extraFlags: UInt8 = 0,
    multiFecFlags: UInt8 = 0,
    multiFecBlocks: UInt8 = 0,
    fecInfo: UInt32 = 0,
    payload: Data
) -> Data {
    var data = Data()
    data.append(contentsOf: [
        UInt8(truncatingIfNeeded: streamPacketIndex),
        UInt8(truncatingIfNeeded: streamPacketIndex >> 8),
        UInt8(truncatingIfNeeded: streamPacketIndex >> 16),
        UInt8(truncatingIfNeeded: streamPacketIndex >> 24),
        UInt8(truncatingIfNeeded: frameIndex),
        UInt8(truncatingIfNeeded: frameIndex >> 8),
        UInt8(truncatingIfNeeded: frameIndex >> 16),
        UInt8(truncatingIfNeeded: frameIndex >> 24),
        flags,
        extraFlags,
        multiFecFlags,
        multiFecBlocks,
        UInt8(truncatingIfNeeded: fecInfo),
        UInt8(truncatingIfNeeded: fecInfo >> 8),
        UInt8(truncatingIfNeeded: fecInfo >> 16),
        UInt8(truncatingIfNeeded: fecInfo >> 24)
    ])
    data.append(payload)
    return data
}

private func makeVideoParityPackets(
    _ parityShards: [Data],
    baseSequenceNumber: UInt16,
    timestamp: UInt32,
    frameIndex: UInt32,
    dataShardCount: UInt32,
    fecPercentage: UInt32
) -> [VideoTransportPacket] {
    parityShards.enumerated().map { parityIndex, protectedPayload in
        let shardIndex = dataShardCount + UInt32(parityIndex)
        let video = VideoPacketHeader(
            streamPacketIndex: shardIndex + 1,
            frameIndex: frameIndex,
            flags: 0,
            extraFlags: 0,
            multiFecFlags: 0,
            multiFecBlocks: 0,
            fecInfo: (dataShardCount << 22) | (shardIndex << 12) | (fecPercentage << 4)
        )
        return VideoTransportPacket(
            rtp: RTPHeader(
                packetType: 0x60,
                sequenceNumber: baseSequenceNumber &+ UInt16(shardIndex),
                timestamp: timestamp,
                ssrc: 1
            ),
            video: video,
            payload: Data(),
            fecProtectedPayload: protectedPayload
        )
    }
}

private func makeAudioPacket(
    sequenceNumber: UInt16,
    timestamp: UInt32,
    payloadType: UInt8 = AudioTransportPacket.opusPayloadType,
    payload: Data
) -> Data {
    var data = Data()
    data.append(0x80)
    data.append(payloadType | 0x80)
    data.append(UInt8(truncatingIfNeeded: sequenceNumber >> 8))
    data.append(UInt8(truncatingIfNeeded: sequenceNumber))
    data.append(contentsOf: [
        UInt8(truncatingIfNeeded: timestamp >> 24),
        UInt8(truncatingIfNeeded: timestamp >> 16),
        UInt8(truncatingIfNeeded: timestamp >> 8),
        UInt8(truncatingIfNeeded: timestamp)
    ])
    data.append(contentsOf: [0,0,0,2])
    data.append(payload)
    return data
}

private func sendUDPDatagram(_ payload: Data, to port: UInt16) throws {
    let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard socketFD >= 0 else {
        throw SendError.socketCreationFailed
    }
    defer { close(socketFD) }

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    let inetResult = "127.0.0.1".withCString { cs in
        inet_pton(AF_INET, cs, &address.sin_addr)
    }
    guard inetResult == 1 else {
        throw SendError.invalidAddress
    }

    let sent = payload.withUnsafeBytes { bytes in
        withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                sendto(socketFD, bytes.baseAddress, bytes.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
    guard sent == payload.count else {
        throw SendError.sendFailed
    }
}

private enum SendError: Error {
    case socketCreationFailed
    case invalidAddress
    case sendFailed
}
