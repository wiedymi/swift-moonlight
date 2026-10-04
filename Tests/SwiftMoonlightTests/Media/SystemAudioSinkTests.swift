#if canImport(AVFoundation)
import AVFoundation
import Foundation
import Testing
@testable import SwiftMoonlight

@Test
func pcmBufferBridgeCreatesInterleavedInt16PCMFormat() throws {
    let format = try PCMBufferBridge.makeAVAudioFormat(from: .init(sampleRate: 48_000, channelCount: 2))

    #expect(format.sampleRate == 48_000)
    #expect(format.channelCount == 2)
    #expect(format.commonFormat == .pcmFormatInt16)
    #expect(format.isInterleaved)
}

@Test
func pcmBufferBridgeCopiesInterleavedInt16PCMBytesIntoPlaybackBuffer() throws {
    let source = PCMBuffer(
        sampleRate: 48_000,
        channelCount: 2,
        frameCount: 2,
        bytesPerFrame: 4,
        data: Data([0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x04, 0x00])
    )

    let format = try PCMBufferBridge.makeAVAudioFormat(from: .init(sampleRate: 48_000, channelCount: 2))
    let buffer = try PCMBufferBridge.makeAVAudioPCMBuffer(from: source, format: format)
    let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    let copiedBytes = Data(
        bytes: audioBuffers[0].mData!,
        count: Int(audioBuffers[0].mDataByteSize)
    )

    #expect(buffer.frameLength == 2)
    #expect(audioBuffers.count == 1)
    #expect(copiedBytes == source.data)
}

@Test
func pcmBufferBridgeRejectsChannelMismatchBeforeCopying() throws {
    let format = try PCMBufferBridge.makeAVAudioFormat(from: .init(sampleRate: 48_000, channelCount: 2))
    let source = PCMBuffer(sampleRate: 48_000, channelCount: 8, frameCount: 240,
                           bytesPerFrame: 16, data: Data(count: 240 * 16))
    #expect(throws: MoonlightError.self) {
        try PCMBufferBridge.makeAVAudioPCMBuffer(from: source, format: format)
    }
}

@Test
func systemAudioSinkBuffersShortPacketsAndUsesRenderedTime() async throws {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let output = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    try engine.enableManualRenderingMode(.offline, format: output, maximumFrameCount: 512)
    let sink = SystemAudioSink(engine: engine, playerNode: player)
    try await sink.prepare(format: .init(sampleRate: 48_000, channelCount: 2))
    let packet = PCMBuffer(sampleRate: 48_000, channelCount: 2, frameCount: 240,
                           bytesPerFrame: 4, data: Data((0..<480).flatMap { _ in [UInt8(0xe8), 0x03] }))
    for _ in 0..<3 { #expect(await sink.play(packet) == .accepted) }
    #expect(!player.isPlaying)
    #expect(await sink.play(packet) == .accepted)
    #expect(player.isPlaying)
    // A recovered 40 ms burst fits without dropping source samples.
    for _ in 0..<8 { #expect(await sink.play(packet) == .accepted) }
    let rendered = try #require(AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 512))
    for index in 0..<8 {
        #expect(try engine.renderOffline(512, to: rendered) == .success)
        if index < 5 {
            let samples = try #require(rendered.floatChannelData)
            for frame in 0..<512 { #expect(abs(samples[0][frame] - Float(1000) / 32768) < 0.0001) }
        }
    }
    // Once empty, collect another 20 ms before restarting.
    #expect(await sink.play(packet) == .accepted)
    #expect(!player.isPlaying)
    for _ in 0..<3 { #expect(await sink.play(packet) == .accepted) }
    #expect(player.isPlaying)
    await sink.teardown()
}
#endif
