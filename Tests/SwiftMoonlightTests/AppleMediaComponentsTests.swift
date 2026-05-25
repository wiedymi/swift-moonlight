#if canImport(Metal) && canImport(QuartzCore) && canImport(AVFoundation)
import AVFoundation
import Metal
import QuartzCore
import Testing
@testable import SwiftMoonlight

@Test
func appleMediaComponentsRejectsSoftwareFallbackModeWithoutDecoder() throws {
    do {
        _ = try AppleMediaComponents.makeVideoDecoder(preferredDecodeMode: .softwareFallback)
        Issue.record("Expected software fallback decoder creation to fail")
    } catch let error as MoonlightError {
        #expect(error.code == .unsupportedOperation)
        #expect(error.message.contains("software video decoder"))
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

@Test
func appleMediaComponentsHonorsHardwareOnlyDecodeMode() throws {
    let decoder = try AppleMediaComponents.makeVideoDecoder(
        preferredDecodeMode: .hardwareOnly,
        softwareFallback: RecordingVideoDecoder()
    )

    #expect(decoder is VideoToolboxDecoder)
}

@Test
func appleMediaComponentsAttachRecommendedPlaybackStack() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw TestSkip.unavailableGPU
    }

    let layer = CAMetalLayer()
    layer.device = device

    let session = MoonlightSession()
    try await AppleMediaComponents.attachRecommendedPlaybackComponents(
        to: session,
        device: device,
        layer: layer
    )

    let metrics = await session.metrics
    var iterator = metrics.makeAsyncIterator()
    _ = await iterator.next()
    _ = await iterator.next()
    let lastSnapshot = await iterator.next()

    #expect(lastSnapshot?.rendererAttachments == 1)
    #expect(lastSnapshot?.audioSinkAttachments == 1)
}

private enum TestSkip: Error {
    case unavailableGPU
}
#endif
