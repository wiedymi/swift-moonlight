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
