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
