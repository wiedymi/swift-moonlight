#if canImport(VideoToolbox) && canImport(CoreVideo)
import CoreGraphics
import CoreVideo
import Foundation
import Testing
@testable import SwiftMoonlight

@Test
func videoToolboxDecoderRejectsAV1UntilFormatDescriptionSupportExists() async throws {
    let decoder = VideoToolboxDecoder()
    let format = VideoFormat(codec: .av1, dimensions: CGSize(width: 1920, height: 1080))

    do {
        try await decoder.configure(format: format)
        Issue.record("Expected AV1 VideoToolbox configuration to fail")
    } catch let error as MoonlightError {
        #expect(error.code == .unsupportedOperation)
        #expect(error.message.contains("AV1"))
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

@Test
func videoToolboxDecoderRequestsUncompressedNV12ForSDROutput() {
    let attrs = VideoToolboxDecoder.imageBufferAttributes(
        for: VideoFormat(
            codec: .hevc,
            dimensions: CGSize(width: 1920, height: 1080),
            dynamicRange: .sdr
        )
    )

    #expect(attrs[kCVPixelBufferPixelFormatTypeKey] as? OSType == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    #expect(attrs[kCVPixelBufferMetalCompatibilityKey] as? Bool == true)
    #expect(attrs[kCVPixelBufferIOSurfacePropertiesKey] != nil)
}

@Test
func videoToolboxDecoderRequestsUncompressedP010ForHDROutput() {
    let attrs = VideoToolboxDecoder.imageBufferAttributes(
        for: VideoFormat(
            codec: .hevc,
            dimensions: CGSize(width: 1920, height: 1080),
            dynamicRange: .hdr
        )
    )

    #expect(attrs[kCVPixelBufferPixelFormatTypeKey] as? OSType == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
    #expect(attrs[kCVPixelBufferMetalCompatibilityKey] as? Bool == true)
    #expect(attrs[kCVPixelBufferIOSurfacePropertiesKey] != nil)
}
@Test
func videoToolboxAsynchronousDecodeReturnsRealFramesInOrder() async throws {
    let decoder = VideoToolboxDecoder()
    try await decoder.configure(format: .init(codec: .h264, dimensions: CGSize(width: 64, height: 64)))
    let payload = try fixtureData(named: "video_h264_64x64.frame")
    for timestamp in UInt64(1)...20 {
        let frames = try await decoder.decode(.init(timestamp: timestamp, isKeyFrame: true,
            codec: .h264, payload: payload))
        let frame = try #require(frames.first)
        #expect(frames.count == 1)
        #expect(frame.timestamp == timestamp)
        let pixels = try #require(frame.pixelBuffer?.pixelBuffer)
        #expect(CVPixelBufferGetWidth(pixels) == 64)
        #expect(CVPixelBufferGetHeight(pixels) == 64)
        #expect(CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    }
    #expect(try await decoder.flush().isEmpty)
}
#endif
