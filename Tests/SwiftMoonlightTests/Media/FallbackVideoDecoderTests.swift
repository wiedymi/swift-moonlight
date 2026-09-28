import CoreGraphics
import Foundation
import Testing
@testable import SwiftMoonlight

@Test
func fallbackVideoDecoderPromotesFallbackAfterPrimaryConfigureFailure() async throws {
    let format = VideoFormat(codec: .av1, dimensions: CGSize(width: 3840, height: 2160))
    let primary = FailingVideoDecoder(
        configureError: MoonlightError(.unsupportedOperation, message: "AV1 VideoToolbox decode is not implemented yet"),
        failAfterDecodeCount: nil
    )
    let fallbackOutput = DecodedVideoFrame(
        timestamp: 200,
        dimensions: CGSize(width: 3840, height: 2160),
        bytes: Data([0xA1])
    )
    let fallback = RecordingVideoDecoder(decodeOutputs: [[fallbackOutput]])
    let decoder = FallbackVideoDecoder(primary: primary, fallback: fallback)
    let frame = EncodedVideoFrame(
        timestamp: 200,
        isKeyFrame: true,
        codec: .av1,
        payload: Data([0x12, 0x00])
    )

    try await decoder.configure(format: format)
    let output = try await decoder.decode(frame)

    #expect(output == [fallbackOutput])
    #expect(await decoder.currentDecoder() == .fallback)
    #expect(await primary.recordedFormats() == [format])
    #expect(await fallback.recordedFormats() == [format])
    #expect(await fallback.recordedInputs() == [frame])
}

@Test
func fallbackVideoDecoderPromotesFallbackAfterPrimaryFailure() async throws {
    let primary = FailingVideoDecoder(failAfterDecodeCount: 0)
    let fallbackOutput = DecodedVideoFrame(
        timestamp: 100,
        dimensions: CGSize(width: 1920, height: 1080),
        bytes: Data([0xAA])
    )
    let fallback = RecordingVideoDecoder(decodeOutputs: [[fallbackOutput]])
    let decoder = FallbackVideoDecoder(primary: primary, fallback: fallback)
    let format = VideoFormat(codec: .h264, dimensions: CGSize(width: 1920, height: 1080))
    let frame = EncodedVideoFrame(
        timestamp: 100,
        isKeyFrame: true,
        codec: .h264,
        payload: Data([0x00, 0x00, 0x01, 0x65])
    )

    try await decoder.configure(format: format)
    let output = try await decoder.decode(frame)

    #expect(output == [fallbackOutput])
    #expect(await decoder.currentDecoder() == .fallback)
    #expect(await fallback.recordedFormats() == [format])
    #expect(await fallback.recordedInputs() == [frame])
}

@Test
func fallbackVideoDecoderStaysOnPrimaryWhenPrimarySucceeds() async throws {
    let primaryOutput = DecodedVideoFrame(
        timestamp: 55,
        dimensions: CGSize(width: 1280, height: 720),
        bytes: Data([0x10])
    )
    let primary = RecordingVideoDecoder(decodeOutputs: [[primaryOutput]])
    let fallback = RecordingVideoDecoder()
    let decoder = FallbackVideoDecoder(primary: primary, fallback: fallback)
    let format = VideoFormat(codec: .hevc, dimensions: CGSize(width: 1280, height: 720))
    let frame = EncodedVideoFrame(
        timestamp: 55,
        isKeyFrame: true,
        codec: .hevc,
        payload: Data([0x00, 0x00, 0x01, 0x26])
    )

    try await decoder.configure(format: format)
    let output = try await decoder.decode(frame)

    #expect(output == [primaryOutput])
    #expect(await decoder.currentDecoder() == .primary)
    #expect(await primary.recordedFormats() == [format])
    #expect(await primary.recordedInputs() == [frame])
    #expect(await fallback.recordedFormats().isEmpty)
    #expect(await fallback.recordedInputs().isEmpty)
}
