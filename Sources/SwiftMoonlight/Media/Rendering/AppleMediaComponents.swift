#if canImport(Metal) && canImport(QuartzCore) && canImport(AVFoundation)
import AVFoundation
import Metal
import QuartzCore

public enum AppleMediaComponents {
    public static func makeVideoDecoder(
        softwareFallback: (any VideoDecoder)? = nil
    ) -> any VideoDecoder {
        let primary = VideoToolboxDecoder()
        if let softwareFallback {
            return FallbackVideoDecoder(primary: primary, fallback: softwareFallback)
        }
        return primary
    }

    public static func makeVideoDecoder(
        preferredDecodeMode: DecodeModePreference,
        softwareFallback: (any VideoDecoder)? = nil
    ) throws -> any VideoDecoder {
        switch preferredDecodeMode {
        case .hardwareOnly:
            return VideoToolboxDecoder()
        case .hardwareFirst:
            return makeVideoDecoder(softwareFallback: softwareFallback)
        case .softwareFallback:
            guard let softwareFallback else {
                throw MoonlightError(.unsupportedOperation, message: "Software fallback decode mode requires a software video decoder")
            }
            return FallbackVideoDecoder(primary: VideoToolboxDecoder(), fallback: softwareFallback)
        }
    }

    @MainActor public static func makeRenderer(
        device: any MTLDevice,
        layer: CAMetalLayer,
        presentationConfiguration: MetalPresentationConfiguration = MetalPresentationConfiguration(),
        frameDiagnosticsHandler: (@MainActor @Sendable (MetalFrameDiagnostics) -> Void)? = nil
    ) throws -> any FrameRenderer {
        let target = try MetalLayerTarget(
            device: device,
            layerReference: MetalLayerReference(layer: layer),
            presentationConfiguration: presentationConfiguration
        )
        let diagnosticsHandler: (@Sendable (MetalFrameDiagnostics) async -> Void)?
        if let frameDiagnosticsHandler {
            diagnosticsHandler = { diagnostics in
                await frameDiagnosticsHandler(diagnostics)
            }
        } else {
            diagnosticsHandler = nil
        }
        return try MetalRenderer(device: device, target: target, diagnosticsHandler: diagnosticsHandler)
    }

    public static func makeAudioDecoder() -> any AudioDecoder {
        OpusDecoder()
    }

    public static func makeAudioSink() -> any AudioSink {
        SystemAudioSink()
    }

    @MainActor public static func attachRecommendedPlaybackComponents(
        to session: MoonlightSession,
        device: any MTLDevice,
        layer: CAMetalLayer,
        preferredDecodeMode: DecodeModePreference = .hardwareFirst,
        softwareFallbackVideoDecoder: (any VideoDecoder)? = nil,
        presentationConfiguration: MetalPresentationConfiguration = MetalPresentationConfiguration(),
        frameDiagnosticsHandler: (@MainActor @Sendable (MetalFrameDiagnostics) -> Void)? = nil
    ) async throws {
        try await session.attachVideoDecoder(
            try makeVideoDecoder(
                preferredDecodeMode: preferredDecodeMode,
                softwareFallback: softwareFallbackVideoDecoder
            )
        )
        try await session.attachRenderer(
            try makeRenderer(
                device: device,
                layer: layer,
                presentationConfiguration: presentationConfiguration,
                frameDiagnosticsHandler: frameDiagnosticsHandler
            )
        )
        try await session.attachAudioDecoder(makeAudioDecoder())
        try await session.attachAudioSink(makeAudioSink())
    }
}
#endif
