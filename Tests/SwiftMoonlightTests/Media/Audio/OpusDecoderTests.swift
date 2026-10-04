#if canImport(AudioToolbox)
import Foundation
import Testing
@testable import SwiftMoonlight

@Test(arguments: [2, 6, 8], [240, 960])
func opusDecoderMatchesReferencePacketsAndConcealment(channels: Int, frames: Int) async throws {
    let config = opusTestConfiguration(channels)
    let decoder = OpusDecoder()
    try await decoder.configure(format: .init(sampleRate: 48_000, channelCount: channels, opusConfiguration: config))
    let prefix = frames == 240 ? "opus_short" : "opus"
    let reference = try opusFixture("\(prefix)_\(channels)ch_reference", extension: "pcm")
    for index in 0..<4 {
        let payload = index < 3 ? try opusFixture("\(prefix)_\(channels)ch_\(index)", extension: "packet") : Data()
        let pcm = try await decoder.decode(.init(timestamp: UInt64(index * frames), payload: payload, isConcealment: index == 3))
        #expect(pcm.sampleRate == 48_000)
        #expect(pcm.channelCount == channels)
        #expect(pcm.frameCount == frames)
        #expect(pcm.bytesPerFrame == channels * 2)
        #expect(pcm.data.count == frames * channels * 2)
        let offset = index * pcm.data.count
        let expected = reference.subdata(in: offset..<(offset + pcm.data.count))
        var largestDifference = 0
        pcm.data.withUnsafeBytes { actualBytes in
            expected.withUnsafeBytes { expectedBytes in
                for offset in stride(from: 0, to: pcm.data.count, by: 2) {
                    let actual = Int(Int16(littleEndian: actualBytes.loadUnaligned(fromByteOffset: offset, as: Int16.self)))
                    let expected = Int(Int16(littleEndian: expectedBytes.loadUnaligned(fromByteOffset: offset, as: Int16.self)))
                    largestDifference = max(largestDifference, abs(actual - expected))
                }
            }
        }
        // Allow small codec rounding differences, including short-packet concealment.
        #expect(largestDifference <= 16)
    }
    // The decoder must continue after the input callback runs out of packets.
    let resumed = try await decoder.decode(.init(timestamp: 3840, payload: opusFixture("\(prefix)_\(channels)ch_2", extension: "packet")))
    #expect(resumed.frameCount == frames)
}

@Test
func opusDecoderRequiresConfigurationAndCanReconfigure() async throws {
    let decoder = OpusDecoder()
    let packet = EncodedAudioPacket(timestamp: 0, payload: try opusFixture("opus_2ch_0", extension: "packet"))
    await #expect(throws: MoonlightError.self) { try await decoder.decode(packet) }
    try await decoder.configure(format: .init(sampleRate: 48_000, channelCount: 2))
    let first = try await decoder.decode(packet)
    try await decoder.configure(format: .init(sampleRate: 48_000, channelCount: 2))
    #expect(try await decoder.decode(packet) == first)
    // Failed configuration must preserve the existing decoder.
    await #expect(throws: MoonlightError.self) {
        try await decoder.configure(format: .init(sampleRate: Int.max, channelCount: Int.max))
    }
    #expect(try await decoder.decode(packet).frameCount == 960)
}

@Test
func opusDecoderRejectsInvalidConfigurations() async throws {
    let decoder = OpusDecoder()
    for config in [
        OpusStreamConfiguration(sampleRate: 48_000, channelCount: 2, streams: Int.max, coupledStreams: 1, samplesPerFrame: 960, mapping: [0, 1]),
        OpusStreamConfiguration(sampleRate: 48_000, channelCount: 2, streams: 1, coupledStreams: 1, samplesPerFrame: Int.max, mapping: [0, 1]),
        OpusStreamConfiguration(sampleRate: 48_000, channelCount: 2, streams: 1, coupledStreams: 1, samplesPerFrame: 960, mapping: [0]),
        OpusStreamConfiguration(sampleRate: 48_000, channelCount: 2, streams: 1, coupledStreams: 1, samplesPerFrame: 960, mapping: [0, 2]),
    ] {
        await #expect(throws: MoonlightError.self) {
            try await decoder.configure(format: .init(sampleRate: 48_000, channelCount: 2, opusConfiguration: config))
        }
    }
    await #expect(throws: MoonlightError.self) {
        try await decoder.configure(format: .init(sampleRate: 48_000, channelCount: 6))
    }
}

@Test
func opusDecoderHandlesInitialAndRepeatedLoss() async throws {
    let decoder = OpusDecoder()
    try await decoder.configure(format: .init(sampleRate: 48_000, channelCount: 2))
    for _ in 0..<3 {
        let pcm = try await decoder.decode(.init(timestamp: 0, payload: Data(), isConcealment: true))
        #expect(pcm.frameCount == 960)
        #expect(pcm.data.count == 3840)
    }
    #expect(try await decoder.decode(.init(timestamp: 0, payload: opusFixture("opus_2ch_0", extension: "packet"))).frameCount == 960)
}

@Test
func opusDecoderRejectsMalformedPacketAndContinues() async throws {
    let decoder = OpusDecoder()
    try await decoder.configure(format: .init(sampleRate: 48_000, channelCount: 2))
    for bytes: [UInt8] in [[3], [3, 0], [3, 63], [0xff, 0xff], [0x9a, 255]] {
        await #expect(throws: MoonlightError.self) {
            try await decoder.decode(.init(timestamp: 0, payload: Data(bytes)))
        }
    }
    #expect(try await decoder.decode(.init(timestamp: 0, payload: opusFixture("opus_2ch_0", extension: "packet"))).frameCount == 960)
}

@Test
func opusPacketDurationIncludesShortAndLongFrames() throws {
    #expect(try OpusDecoder.frameCount(Data([0x80]), sampleRate: 48_000) == 120)
    #expect(try OpusDecoder.frameCount(Data([0x88]), sampleRate: 48_000) == 240)
    #expect(try OpusDecoder.frameCount(Data([0x90]), sampleRate: 48_000) == 480)
    #expect(try OpusDecoder.frameCount(Data([0x98]), sampleRate: 48_000) == 960)
    #expect(try OpusDecoder.frameCount(Data([0x18]), sampleRate: 48_000) == 2880)
    #expect(try OpusDecoder.frameCount(Data([0x19]), sampleRate: 48_000) == 5760)
    #expect(try OpusDecoder.frameCount(Data([0x83, 48]), sampleRate: 48_000) == 5760)
    #expect(throws: MoonlightError.self) { try OpusDecoder.frameCount(Data([0x83, 49]), sampleRate: 48_000) }
    #expect(throws: MoonlightError.self) { try OpusDecoder.frameCount(Data([0x83, 48]), sampleRate: Int.max) }
}

private func opusTestConfiguration(_ channels: Int) -> OpusStreamConfiguration {
    if channels == 2 { return .stereo() }
    return .init(sampleRate: 48_000, channelCount: channels, streams: channels == 6 ? 4 : 5,
                 coupledStreams: channels == 6 ? 2 : 3, samplesPerFrame: 960,
                 mapping: channels == 6 ? [0, 4, 1, 5, 2, 3] : [0, 6, 1, 7, 2, 3, 4, 5])
}

private func opusFixture(_ name: String, extension fileExtension: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: fileExtension))
    return try Data(contentsOf: url)
}
#endif
