import CoreGraphics
import Foundation
import Testing
@testable import SwiftMoonlight

@Test
func videoReorderWindowStaysWithinSequenceRange() {
    var zero = VideoDepacketizerConfiguration(codec: .h264, dimensions: CGSize(width: 640, height: 360), reorderWindowSize: 0)
    let huge = VideoDepacketizerConfiguration(codec: .h264, dimensions: CGSize(width: 640, height: 360), reorderWindowSize: Int.max)

    #expect(zero.reorderWindowSize == 1)
    #expect(huge.reorderWindowSize == 32_767)
    zero.reorderWindowSize = Int.max
    #expect(zero.reorderWindowSize == 32_767)
}
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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

@Test(arguments: [UInt16(1000), UInt16(65500)], [0, 1, 60])
func depacketizerRecoversLargeFECBlockBeyondDefaultReorderWindow(base: UInt16, missingIndex: Int) async throws {
    let count = 100
    let percentage: UInt32 = 10
    let parser = VideoPacketParser()
    let packets = try (0..<count).map { index in
        let flags = index == 0 ? VideoPacketHeader.startOfFrameFlag :
            index == count - 1 ? VideoPacketHeader.endOfFrameFlag : VideoPacketHeader.containsPictureDataFlag
        return try parser.parse(makeVideoPacket(
            sequenceNumber: base &+ UInt16(index), timestamp: 6000,
            streamPacketIndex: UInt32(index + 1), frameIndex: 80, flags: flags,
            fecInfo: (UInt32(count) << 22) | (UInt32(index) << 12) | (percentage << 4),
            payload: Data(repeating: UInt8(index), count: 8)
        ))
    }
    let codec = try ReedSolomonFEC(dataShardCount: count, parityShardCount: 10)
    let parity = makeVideoParityPackets(try codec.encodeParityShards(packets.map(\.fecProtectedPayload)),
        baseSequenceNumber: base, timestamp: 6000, frameIndex: 80,
        dataShardCount: UInt32(count), fecPercentage: percentage)
    let depacketizer = SimpleVideoDepacketizer(configuration: .init(
        codec: .h264, dimensions: CGSize(width: 2934, height: 1554), frameHeaderSize: 0))
    var frame: EncodedVideoFrame?
    for (index, packet) in packets.enumerated() where index != missingIndex {
        frame = try await depacketizer.submit(packet) ?? frame
    }
    for packet in parity {
        frame = try await depacketizer.submit(packet) ?? frame
    }
    #expect(frame?.payload == packets.reduce(into: Data()) { $0.append($1.payload) })
    #expect(await depacketizer.snapshotDiscontinuityCount() == 0)
}

@Test
func depacketizerRejectsOversizedRepairBlockWithoutExtendingWait() async throws {
    let parser = VideoPacketParser()
    let depacketizer = SimpleVideoDepacketizer(configuration: .init(
        codec: .h264, dimensions: CGSize(width: 640, height: 360), frameHeaderSize: 0, reorderWindowSize: 1))
    for index in [0, 3] {
        _ = try await depacketizer.submit(parser.parse(makeVideoPacket(
            sequenceNumber: UInt16(100 + index), timestamp: 1,
            streamPacketIndex: UInt32(index), frameIndex: 1,
            flags: index == 0 ? VideoPacketHeader.startOfFrameFlag : VideoPacketHeader.containsPictureDataFlag,
            fecInfo: (UInt32(1000) << 22) | (UInt32(index) << 12) | (UInt32(20) << 4),
            payload: Data([0xAA])
        )))
    }
    #expect(await depacketizer.snapshotDiscontinuityCount() == 1)
}

@Test
func depacketizerAdvancesPastUnrecoverableLargeRepairBlock() async throws {
    let parser = VideoPacketParser()
    let depacketizer = SimpleVideoDepacketizer(configuration: .init(
        codec: .h264, dimensions: CGSize(width: 640, height: 360), frameHeaderSize: 0))
    // 100 data shards plus 10 parity shards. Missing data cannot be reconstructed here.
    for index in [0, 99, 109] {
        _ = try await depacketizer.submit(parser.parse(makeVideoPacket(
            sequenceNumber: UInt16(1000 + index), timestamp: 1,
            streamPacketIndex: UInt32(index), frameIndex: 1,
            flags: index == 0 ? VideoPacketHeader.startOfFrameFlag :
                index == 99 ? VideoPacketHeader.endOfFrameFlag : 0,
            fecInfo: (UInt32(100) << 22) | (UInt32(index) << 12) | (UInt32(10) << 4),
            payload: Data([0xAA])
        )))
    }
    let next = try await depacketizer.submit(parser.parse(makeVideoPacket(
        sequenceNumber: 1110, timestamp: 2, streamPacketIndex: 0, frameIndex: 2,
        flags: VideoPacketHeader.startOfFrameFlag | VideoPacketHeader.endOfFrameFlag,
        payload: Data([0xBB])
    )))
    #expect(next?.payload == Data([0xBB]))
    #expect(await depacketizer.snapshotDiscontinuityCount() == 1)
    #expect(await depacketizer.drainPendingFrameFECStatuses().count == 1)
}
