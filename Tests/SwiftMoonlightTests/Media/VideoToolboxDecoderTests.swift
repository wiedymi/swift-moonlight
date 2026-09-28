#if canImport(VideoToolbox) && canImport(CoreVideo)
import CoreGraphics
import CoreVideo
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
#endif
