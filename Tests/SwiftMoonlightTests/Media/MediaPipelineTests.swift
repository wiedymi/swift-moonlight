import CoreGraphics
import Foundation
import Testing
@testable import SwiftMoonlight

private struct DroppingAudioSink: AudioSink {
    func prepare(format: AudioFormat) async throws {}
    func play(_ buffer: PCMBuffer) async -> AudioPlaybackResult { .dropped }
    func teardown() async {}
}

@Test
func mediaPipelineConfiguresVideoAndRendersDecodedFrames() async throws {
    let pipeline = MediaPipeline()
    let outputFrames = [
        DecodedVideoFrame(
            timestamp: 100,
            dimensions: CGSize(width: 1280, height: 720),
            bytes: Data([1, 2, 3])
        )
    ]
    let decoder = RecordingVideoDecoder(decodeOutputs: [outputFrames])
    let renderer = RecordingRenderer()
    let format = VideoFormat(codec: .hevc, dimensions: CGSize(width: 1280, height: 720), dynamicRange: .hdr)

    try await pipeline.attachVideoDecoder(decoder)
    try await pipeline.attachRenderer(renderer)
    try await pipeline.configureVideo(format: format)
    try await pipeline.ingestVideo(.init(
        timestamp: 100,
        isKeyFrame: true,
        codec: .hevc,
        parameterSets: [Data([0x01]), Data([0x02])],
        payload: Data([0xAA, 0xBB])
    ))

    let decoderFormats = await decoder.recordedFormats()
    let rendererFormats = await renderer.recordedFormats()
    let rendererFrames = await renderer.recordedFrames()
    let stats = await pipeline.snapshot()

    #expect(decoderFormats == [format])
    #expect(rendererFormats == [format])
    #expect(rendererFrames == outputFrames)
    #expect(stats.decodedVideoFrames == 1)
    #expect(stats.renderedVideoFrames == 1)
}

@Test
func mediaPipelineMeasuresDecodeLatencyAndUnderruns() async throws {
    let clock = AdvancingTestClock(dates: [
        Date(timeIntervalSince1970: 1.000),
        Date(timeIntervalSince1970: 1.012),
        Date(timeIntervalSince1970: 2.000),
        Date(timeIntervalSince1970: 2.004)
    ])
    let pipeline = MediaPipeline(clock: clock)
    let videoDecoder = RecordingVideoDecoder(decodeOutputs: [[
        DecodedVideoFrame(timestamp: 100, dimensions: CGSize(width: 1280, height: 720), bytes: Data([0x01]))
    ]])
    let audioDecoder = RecordingAudioDecoder(outputs: [
        PCMBuffer(sampleRate: 48_000, channelCount: 2, frameCount: 480, bytesPerFrame: 4, data: Data([0x01, 0x02]))
    ])

    try await pipeline.attachVideoDecoder(videoDecoder)
    try await pipeline.attachRenderer(NullRenderer())
    try await pipeline.attachAudioDecoder(audioDecoder)
    try await pipeline.attachAudioSink(NullAudioSink())
    try await pipeline.configureVideo(format: .init(codec: .hevc, dimensions: CGSize(width: 1280, height: 720)))
    try await pipeline.configureAudio(format: .init(sampleRate: 48_000, channelCount: 2))
    try await pipeline.ingestVideo(.init(timestamp: 100, isKeyFrame: true, codec: .hevc, payload: Data([0xAA])))
    try await pipeline.ingestAudio(.init(timestamp: 200, payload: Data([0xBB]), isConcealment: true))

    let stats = await pipeline.snapshot()
    #expect(approximatelyEqual(stats.averageVideoDecodeLatencyMs, 12))
    #expect(approximatelyEqual(stats.maxVideoDecodeLatencyMs, 12))
    #expect(approximatelyEqual(stats.averageAudioDecodeLatencyMs, 4))
    #expect(approximatelyEqual(stats.maxAudioDecodeLatencyMs, 4))
    #expect(stats.audioUnderrunEvents == 1)
}

@Test
func mediaPipelineTracksHostProcessingLatency() async throws {
    let pipeline = MediaPipeline()
    let videoDecoder = RecordingVideoDecoder(decodeOutputs: [[
        DecodedVideoFrame(timestamp: 100, dimensions: CGSize(width: 1280, height: 720), bytes: Data([0x01]))
    ]])

    try await pipeline.attachVideoDecoder(videoDecoder)
    try await pipeline.attachRenderer(NullRenderer())
    try await pipeline.configureVideo(format: .init(codec: .hevc, dimensions: CGSize(width: 1280, height: 720)))
    try await pipeline.ingestVideo(.init(
        timestamp: 100,
        isKeyFrame: true,
        codec: .hevc,
        hostProcessingLatencyMs: 12.3,
        payload: Data([0xAA])
    ))

    let stats = await pipeline.snapshot()
    #expect(approximatelyEqual(stats.averageHostProcessingLatencyMs, 12.3))
    #expect(approximatelyEqual(stats.maxHostProcessingLatencyMs, 12.3))
}

@Test
func mediaPipelineCachesVideoParameterSetsAcrossFrames() async throws {
    let pipeline = MediaPipeline()
    let decoder = RecordingVideoDecoder(decodeOutputs: [
        [],
        [DecodedVideoFrame(timestamp: 101, dimensions: CGSize(width: 1280, height: 720), bytes: Data([0x01]))]
    ])
    let renderer = RecordingRenderer()

    try await pipeline.attachVideoDecoder(decoder)
    try await pipeline.attachRenderer(renderer)
    try await pipeline.configureVideo(format: .init(codec: .hevc, dimensions: CGSize(width: 1280, height: 720)))
    try await pipeline.ingestVideo(.init(
        timestamp: 100,
        isKeyFrame: true,
        codec: .hevc,
        payload: Data([
            0x00, 0x00, 0x00, 0x01, 0x40, 0x01,
            0x00, 0x00, 0x01, 0x42, 0x01,
            0x00, 0x00, 0x01, 0x44, 0x01,
            0x00, 0x00, 0x01, 0x26, 0x01
        ])
    ))
    try await pipeline.ingestVideo(.init(
        timestamp: 101,
        isKeyFrame: false,
        codec: .hevc,
        payload: Data([
            0x00, 0x00, 0x00, 0x01, 0x26, 0x02
        ])
    ))

    let decodedInputs = await decoder.recordedInputs()
    let renderedFrames = await renderer.recordedFrames()

    #expect(decodedInputs.count == 2)
    #expect(decodedInputs[0].parameterSets.map(\.hexString) == ["4001", "4201", "4401"])
    #expect(decodedInputs[1].parameterSets.map(\.hexString) == ["4001", "4201", "4401"])
    #expect(renderedFrames.count == 1)
}

@Test
func mediaPipelineFlushesPendingVideoFrames() async throws {
    let pipeline = MediaPipeline()
    let decoder = RecordingVideoDecoder(flushOutputs: [[
        DecodedVideoFrame(
            timestamp: 200,
            dimensions: CGSize(width: 1920, height: 1080),
            bytes: Data([9, 9])
        )
    ]])
    let renderer = RecordingRenderer()

    try await pipeline.attachVideoDecoder(decoder)
    try await pipeline.attachRenderer(renderer)
    try await pipeline.configureVideo(format: .init(codec: .h264, dimensions: CGSize(width: 1920, height: 1080)))
    try await pipeline.flushVideo()

    let frames = await renderer.recordedFrames()
    let stats = await pipeline.snapshot()

    #expect(frames.count == 1)
    #expect(frames[0].timestamp == 200)
    #expect(stats.decodedVideoFrames == 1)
    #expect(stats.renderedVideoFrames == 1)
}

@Test
func mediaPipelineConfiguresAudioAndPlaysDecodedBuffers() async throws {
    let pipeline = MediaPipeline()
    let buffer = PCMBuffer(
        sampleRate: 48_000,
        channelCount: 2,
        frameCount: 960,
        bytesPerFrame: 4,
        data: Data(repeating: 0x7F, count: 960 * 4)
    )
    let decoder = RecordingAudioDecoder(outputs: [buffer])
    let sink = RecordingAudioSink()
    let format = AudioFormat(sampleRate: 48_000, channelCount: 2)

    try await pipeline.attachAudioDecoder(decoder)
    try await pipeline.attachAudioSink(sink)
    try await pipeline.configureAudio(format: format)
    try await pipeline.ingestAudio(.init(timestamp: 10, payload: Data([0x01, 0x02])))

    let decoderFormats = await decoder.recordedFormats()
    let sinkFormats = await sink.recordedFormats()
    let playedBuffers = await sink.recordedBuffers()
    let stats = await pipeline.snapshot()

    #expect(decoderFormats == [format])
    #expect(sinkFormats == [format])
    #expect(playedBuffers == [buffer])
    #expect(stats.decodedAudioBuffers == 1)
    #expect(stats.playedAudioBuffers == 1)
}

@Test
func mediaPipelineDoesNotCountDroppedAudioAsPlayed() async throws {
    let pipeline = MediaPipeline()
    let buffer = PCMBuffer(
        sampleRate: 48_000,
        channelCount: 2,
        frameCount: 1,
        bytesPerFrame: 4,
        data: Data(repeating: 0, count: 4)
    )
    try await pipeline.attachAudioDecoder(RecordingAudioDecoder(outputs: [buffer]))
    try await pipeline.attachAudioSink(DroppingAudioSink())
    try await pipeline.configureAudio(format: .init(sampleRate: 48_000, channelCount: 2))

    try await pipeline.ingestAudio(.init(timestamp: 1, payload: Data([0x01])))

    let stats = await pipeline.snapshot()
    #expect(stats.decodedAudioBuffers == 1)
    #expect(stats.playedAudioBuffers == 0)
}

@Test
func sessionRoutesMediaThroughPipeline() async throws {
    let session = MoonlightSession()
    let videoDecoder = RecordingVideoDecoder(decodeOutputs: [[
        DecodedVideoFrame(timestamp: 1, dimensions: CGSize(width: 640, height: 360), bytes: Data([0xFF]))
    ]])
    let renderer = RecordingRenderer()
    let audioDecoder = RecordingAudioDecoder(outputs: [
        PCMBuffer(sampleRate: 48_000, channelCount: 2, frameCount: 480, bytesPerFrame: 4, data: Data([0x00, 0x01]))
    ])
    let sink = RecordingAudioSink()

    try await session.attachVideoDecoder(videoDecoder)
    try await session.attachRenderer(renderer)
    try await session.attachAudioDecoder(audioDecoder)
    try await session.attachAudioSink(sink)
    try await session.configureVideo(format: .init(codec: .hevc, dimensions: CGSize(width: 640, height: 360)))
    try await session.configureAudio(format: .init(sampleRate: 48_000, channelCount: 2))
    try await session.receive(.init(timestamp: 1, isKeyFrame: true, codec: .hevc, payload: Data([0x01])))
    try await session.receive(.init(timestamp: 2, payload: Data([0x02])))

    let renderedFrames = await renderer.recordedFrames()
    let playedBuffers = await sink.recordedBuffers()

    #expect(renderedFrames.count == 1)
    #expect(playedBuffers.count == 1)
}

private func approximatelyEqual(_ lhs: Double?, _ rhs: Double, tolerance: Double = 0.001) -> Bool {
    guard let lhs else {
        return false
    }
    return abs(lhs - rhs) <= tolerance
}
