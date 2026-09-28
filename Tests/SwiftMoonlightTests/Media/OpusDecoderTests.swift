#if canImport(COpus)
import COpus
import Foundation
import Testing
@testable import SwiftMoonlight

@Test
func opusDecoderRoundTripsStereoPacket() async throws {
    let config = OpusStreamConfiguration.stereo()
    let format = AudioFormat(sampleRate: 48_000, channelCount: 2, opusConfiguration: config)
    let packet = try makeEncodedStereoOpusPacket(samplesPerChannel: config.samplesPerFrame)

    let decoder = OpusDecoder()
    try await decoder.configure(format: format)
    let pcm = try await decoder.decode(.init(timestamp: 0, payload: packet))

    #expect(pcm.sampleRate == 48_000)
    #expect(pcm.channelCount == 2)
    #expect(pcm.frameCount > 0)
    #expect(pcm.bytesPerFrame == 4)
    #expect(!pcm.data.isEmpty)
}

private func makeEncodedStereoOpusPacket(samplesPerChannel: Int) throws -> Data {
    var errorCode: Int32 = OPUS_OK
    guard let encoder = opus_encoder_create(48_000, 2, OPUS_APPLICATION_AUDIO, &errorCode) else {
        throw TestOpusError.encoderCreationFailed(errorCode)
    }
    defer {
        opus_encoder_destroy(encoder)
    }
    guard errorCode == OPUS_OK else {
        throw TestOpusError.encoderCreationFailed(errorCode)
    }

    var pcm = [Int16](repeating: 0, count: samplesPerChannel * 2)
    for sampleIndex in 0..<samplesPerChannel {
        let sample = Int16((sampleIndex % 64) * 256)
        pcm[sampleIndex * 2] = sample
        pcm[sampleIndex * 2 + 1] = sample
    }

    var output = [UInt8](repeating: 0, count: 4000)
    let encodedLength = opus_encode(
        encoder,
        &pcm,
        Int32(samplesPerChannel),
        &output,
        Int32(output.count)
    )
    guard encodedLength > 0 else {
        throw TestOpusError.encodeFailed(encodedLength)
    }

    return Data(output.prefix(Int(encodedLength)))
}

private enum TestOpusError: Error {
    case encoderCreationFailed(Int32)
    case encodeFailed(Int32)
}
#endif
