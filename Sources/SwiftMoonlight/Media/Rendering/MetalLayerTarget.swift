#if canImport(Metal) && canImport(QuartzCore)
import CoreGraphics
import Foundation
import Metal
#if canImport(MetalFX)
import MetalFX
#endif
import QuartzCore
#if os(iOS)
import UIKit
#endif

public actor MetalLayerTarget: MetalFrameTarget {
    private let device: MTLDevice
    private let layerReference: MetalLayerReference
    private let presentationConfiguration: MetalPresentationConfiguration
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary
    private let vertexBuffer: MTLBuffer
    private var activeDynamicRangeMode: MetalResolvedPresentationDynamicRangeMode
    private var rgbPipelineState: MTLRenderPipelineState
    private var biPlanarPipelineState: MTLRenderPipelineState
    private var presentationPipelineState: MTLRenderPipelineState
    private let displayPresenter: MetalDisplayPresenter

    @MainActor public init(
        device: MTLDevice,
        layer: CAMetalLayer,
        presentationConfiguration: MetalPresentationConfiguration = MetalPresentationConfiguration()
    ) throws {
        try self.init(
            device: device,
            layerReference: MetalLayerReference(layer: layer),
            presentationConfiguration: presentationConfiguration
        )
    }

    internal init(
        device: MTLDevice,
        layerReference: MetalLayerReference,
        presentationConfiguration: MetalPresentationConfiguration = MetalPresentationConfiguration()
    ) throws {
        self.device = device
        self.layerReference = layerReference
        self.presentationConfiguration = presentationConfiguration
        self.activeDynamicRangeMode = presentationConfiguration.resolvedDynamicRangeMode(for: nil)

        guard let commandQueue = device.makeCommandQueue() else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to create Metal command queue")
        }
        self.commandQueue = commandQueue

        let vertices: [Float] = [
            -1, -1, 0, 1,
             3, -1, 2, 1,
            -1,  3, 0, -1
        ]
        guard let vertexBuffer = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<Float>.stride) else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to create Metal vertex buffer")
        }
        self.vertexBuffer = vertexBuffer

        let library = try device.makeDefaultSwiftMoonlightLibrary()
        self.library = library
        self.rgbPipelineState = try device.makeRenderPipelineState(
            descriptor: Self.makePipelineDescriptor(
                library: library,
                fragmentFunction: "fragmentRGB",
                pixelFormat: activeDynamicRangeMode.drawablePixelFormat
            )
        )
        self.biPlanarPipelineState = try device.makeRenderPipelineState(
            descriptor: Self.makePipelineDescriptor(
                library: library,
                fragmentFunction: "fragmentBiPlanar",
                pixelFormat: activeDynamicRangeMode.drawablePixelFormat
            )
        )
        self.presentationPipelineState = try device.makeRenderPipelineState(
            descriptor: Self.makePipelineDescriptor(library: library,
                fragmentFunction: "fragmentPresentation", pixelFormat: activeDynamicRangeMode.drawablePixelFormat)
        )
        self.displayPresenter = MetalDisplayPresenter(
            commandQueue: commandQueue,
            vertexBuffer: vertexBuffer,
            contentMode: presentationConfiguration.contentMode,
            preferredFrameRate: presentationConfiguration.preferredFrameRate,
            device: device,
            upscalingMode: presentationConfiguration.upscalingMode,
            background: presentationConfiguration.background
        )
    }

    public func prepare(format: VideoFormat) async throws {
        try activateDynamicRangeMode(presentationConfiguration.resolvedDynamicRangeMode(for: format))

        let layerReference = self.layerReference
        let device = self.device
        let mode = activeDynamicRangeMode
        let rgbPipelineState = self.rgbPipelineState
        let biPlanarPipelineState = self.biPlanarPipelineState
        let presentationPipelineState = self.presentationPipelineState
        let displayPresenter = self.displayPresenter
        await MainActor.run {
            let layer = layerReference.layer
            layer.device = device
            layer.pixelFormat = mode.drawablePixelFormat
            layer.colorspace = mode.layerColorSpace
            layer.framebufferOnly = false
            layer.isOpaque = true
            let wantsEDR = mode == .extendedDynamicRange
            #if os(macOS) || os(iOS)
            layer.wantsExtendedDynamicRangeContent = wantsEDR
            if #available(macOS 26.0, iOS 26.0, *) {
                layer.preferredDynamicRange = wantsEDR ? .high : .standard
            }
            #endif
            if layer.drawableSize.width <= 1 || layer.drawableSize.height <= 1 {
                layer.drawableSize = CGSize(
                    width: max(format.dimensions.width.rounded(.up), 1),
                    height: max(format.dimensions.height.rounded(.up), 1)
                )
            }
            displayPresenter.configure(
                rgbPipelineState: rgbPipelineState,
                biPlanarPipelineState: biPlanarPipelineState,
                presentationPipelineState: presentationPipelineState,
                dynamicRangeMode: mode
            )
        }
        await displayPresenter.start(layer: layerReference)
    }

    public func currentPresentationDiagnostics() -> MetalPresentationDiagnostics? {
        displayPresenter.currentDiagnostics()
    }

    public func setPreferredFrameRate(_ rate: Int) async {
        await displayPresenter.setPreferredFrameRate(rate)
    }

    public func present(_ frame: MetalPresentedFrame) async {
        displayPresenter.enqueue(frame)
    }

    /// Keeps the last decoded frame blurred until prepare and the next stream frame.
    public func beginTransition() {
        displayPresenter.beginTransition()
    }

    /// Cancels a pending restart and fades back to the current picture.
    public func endTransition() {
        displayPresenter.endTransition()
    }

    public func teardown() async {
        await displayPresenter.stop()
    }

    private func activateDynamicRangeMode(_ mode: MetalResolvedPresentationDynamicRangeMode) throws {
        guard mode != activeDynamicRangeMode else {
            return
        }

        rgbPipelineState = try device.makeRenderPipelineState(
            descriptor: Self.makePipelineDescriptor(
                library: library,
                fragmentFunction: "fragmentRGB",
                pixelFormat: mode.drawablePixelFormat
            )
        )
        biPlanarPipelineState = try device.makeRenderPipelineState(
            descriptor: Self.makePipelineDescriptor(
                library: library,
                fragmentFunction: "fragmentBiPlanar",
                pixelFormat: mode.drawablePixelFormat
            )
        )
        presentationPipelineState = try device.makeRenderPipelineState(
            descriptor: Self.makePipelineDescriptor(library: library,
                fragmentFunction: "fragmentPresentation", pixelFormat: mode.drawablePixelFormat)
        )
        activeDynamicRangeMode = mode
    }

    private static func makePipelineDescriptor(
        library: MTLLibrary,
        fragmentFunction: String,
        pixelFormat: MTLPixelFormat
    ) -> MTLRenderPipelineDescriptor {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.vertexFunction = library.makeFunction(name: "vertexMain")
        descriptor.fragmentFunction = library.makeFunction(name: fragmentFunction)
        return descriptor
    }
}

// The display callback and decoder run on different executors. The lock only
// transfers the latest decoded frame and immutable pipeline state snapshots.
final class MetalDisplayPresenter: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    struct RenderState {
        let rgbPipelineState: MTLRenderPipelineState
        let biPlanarPipelineState: MTLRenderPipelineState
        let presentationPipelineState: MTLRenderPipelineState
        let dynamicRangeMode: MetalResolvedPresentationDynamicRangeMode
    }

    private let lock = NSLock()
    private let commandQueue: MTLCommandQueue
    private let vertexBuffer: MTLBuffer
    private let contentMode: MetalPresentationContentMode
    @MainActor private var preferredFrameRate: Int?
    private let device: MTLDevice
    private let upscalingMode: MetalPresentationUpscalingMode
    private let background: MetalPresentationBackground
    // Only the serial display callback uses these GPU resources.
    private var blurredBackground: MetalBlurredBackground?
    #if canImport(MetalFX)
    private var spatialUpscaler: MetalSpatialUpscaler?
    #endif
    private var colorTexture: MTLTexture?
    private var lastPresentationOpacity: Float?
    private var lastDrawableSize: CGSize?
    private var transitionStartedAt: CFTimeInterval?
    private var pendingFrame: MetalPresentedFrame?
    private var renderState: RenderState?
    private var diagnostics: MetalPresentationDiagnostics?
    private enum Transition {
        case clear
        case waitingForStream
        case waitingForFrame
        case fading(CFTimeInterval)
    }
    private var transition = Transition.clear
    private var hasNewFrame = false
    @MainActor private var displayLink: CAMetalDisplayLink?

    init(commandQueue: MTLCommandQueue, vertexBuffer: MTLBuffer,
         contentMode: MetalPresentationContentMode, preferredFrameRate: Int?,
         device: MTLDevice,
         upscalingMode: MetalPresentationUpscalingMode, background: MetalPresentationBackground) {
        self.commandQueue = commandQueue
        self.vertexBuffer = vertexBuffer
        self.contentMode = contentMode
        self.preferredFrameRate = preferredFrameRate
        self.device = device
        self.upscalingMode = upscalingMode
        self.background = background
    }

    func configure(
        rgbPipelineState: MTLRenderPipelineState,
        biPlanarPipelineState: MTLRenderPipelineState,
        presentationPipelineState: MTLRenderPipelineState,
        dynamicRangeMode: MetalResolvedPresentationDynamicRangeMode
    ) {
        lock.lock()
        renderState = RenderState(
            rgbPipelineState: rgbPipelineState,
            biPlanarPipelineState: biPlanarPipelineState,
            presentationPipelineState: presentationPipelineState,
            dynamicRangeMode: dynamicRangeMode
        )
        if case .waitingForStream = transition { transition = .waitingForFrame }
        lock.unlock()
    }

    func currentDiagnostics() -> MetalPresentationDiagnostics? {
        lock.lock()
        defer { lock.unlock() }
        return diagnostics
    }

    func beginTransition() {
        lock.lock()
        transition = .waitingForStream
        lock.unlock()
    }

    func endTransition() {
        lock.lock()
        transition = .fading(CACurrentMediaTime())
        lock.unlock()
    }

    func enqueue(_ frame: MetalPresentedFrame) {
        lock.lock()
        pendingFrame = frame
        hasNewFrame = true
        if case .waitingForFrame = transition { transition = .fading(CACurrentMediaTime()) }
        lock.unlock()
    }

    func takePendingFrame(at time: CFTimeInterval = CACurrentMediaTime()) -> (frame: MetalPresentedFrame?, state: RenderState?, opacity: Float, fresh: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let frame = pendingFrame
        let fresh = hasNewFrame
        hasNewFrame = false
        let opacity: Float
        switch transition {
        case .clear: opacity = 1
        case .waitingForStream, .waitingForFrame: opacity = 0
        case .fading(let started):
            opacity = Float(min(max((time - started) / 0.25, 0), 1))
            if opacity == 1 { transition = .clear }
        }
        return (frame, renderState, opacity, fresh)
    }

    @MainActor func start(layer: MetalLayerReference) {
        guard displayLink == nil else { return }
        let link = CAMetalDisplayLink(metalLayer: layer.layer)
        #if os(iOS)
        let screen = (layer.layer.delegate as? UIView)?.window?.windowScene?.screen ?? UIScreen.main
        let maximum = max(screen.maximumFramesPerSecond, 1)
        let preferred = min(max(preferredFrameRate ?? maximum, 1), maximum)
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: Float(min(preferred, 30)), maximum: Float(maximum), preferred: Float(preferred)
        )
        #endif
        link.delegate = self
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @MainActor func setPreferredFrameRate(_ rate: Int) {
        let rate = min(max(rate, 1), 240)
        preferredFrameRate = rate
        #if os(iOS)
        displayLink?.preferredFrameRateRange = CAFrameRateRange(
            minimum: Float(min(rate, 30)), maximum: Float(rate), preferred: Float(rate)
        )
        #endif
    }

    @MainActor func stop() {
        displayLink?.invalidate()
        displayLink = nil
        lock.lock()
        pendingFrame = nil
        diagnostics = nil
        transition = .clear
        hasNewFrame = false
        lock.unlock()
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        let pending = takePendingFrame()

        guard let frame = pending.frame, let state = pending.state,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        autoreleasepool {
            let drawable = update.drawable
            let size = CGSize(width: drawable.texture.width, height: drawable.texture.height)
            let now = CACurrentMediaTime()
            let resized = lastDrawableSize != size
            if resized && background == .blurred {
                transitionStartedAt = now
            }
            lastDrawableSize = size
            let opacity = min(pending.opacity, Float(min(max((now - (transitionStartedAt ?? (now - 1))) / 0.25, 0), 1)))
            guard pending.fresh || resized || opacity != lastPresentationOpacity else { return }
            let transform = MetalPresentationTransform.make(
                contentMode: contentMode, frameDimensions: frame.dimensions, drawableSize: size
            )
            let geometry = MetalPresentationGeometry(contentMode: contentMode,
                frameDimensions: frame.dimensions, drawableSize: size)
            let needsBackground = opacity < 1 || (background == .blurred && geometry.requiresBlurredBackground)
            let usesEffects = needsBackground || upscalingMode == .metalFXSpatial
            let pictureSize = geometry.pictureSize
            var scalingStatus: MetalPresentationScalingStatus = upscalingMode == .linear ? .standard : .fallback
            if usesEffects, let color = convertedTexture(frame: frame, state: state, commandBuffer: commandBuffer) {
                let scaled = opacity > 0 ? upscaledTexture(color: color, frame: frame, size: size,
                                             state: state, commandBuffer: commandBuffer) : nil
                let output = scaled ?? color
                if scaled != nil {
                    scalingStatus = .metalFXSpatial
                } else if upscalingMode == .metalFXSpatial &&
                    (pictureSize.width < CGFloat(color.width) || pictureSize.height < CGFloat(color.height) ||
                     (pictureSize.width == CGFloat(color.width) && pictureSize.height == CGFloat(color.height))) {
                    scalingStatus = .notNeeded
                }
                var backgroundTexture: MTLTexture = color
                if needsBackground {
                    if blurredBackground?.matches(source: color) != true {
                        blurredBackground = MetalBlurredBackground(device: device, source: color)
                    }
                    backgroundTexture = blurredBackground?.encode(source: color, frame: frame, pipeline: state.rgbPipelineState,
                        vertices: vertexBuffer, commandBuffer: commandBuffer) ?? color
                }
                if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass(texture: drawable.texture)) {
                    var fullScreen = MetalPresentationUniform(scale: SIMD2(1, 1))
                    let fill = MetalPresentationTransform.make(contentMode: .aspectFill,
                        frameDimensions: frame.dimensions, drawableSize: size)
                    var effect = SIMD4<Float>(transform.scale.x, transform.scale.y, opacity,
                                             needsBackground ? 1 : 0)
                    var backgroundScale = fill.scale
                    encoder.setRenderPipelineState(state.presentationPipelineState)
                    encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                    encoder.setVertexBytes(&fullScreen, length: MemoryLayout<MetalPresentationUniform>.stride, index: 1)
                    encoder.setFragmentTexture(output, index: 0)
                    encoder.setFragmentTexture(backgroundTexture, index: 1)
                    encoder.setFragmentBytes(&effect, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                    encoder.setFragmentBytes(&backgroundScale, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    encoder.endEncoding()
                }
            } else if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass(texture: drawable.texture)) {
                encodeFrame(frame, state: state, encoder: encoder, scale: transform.scale)
                encoder.endEncoding()
            }
            // CoreVideo frame resources must live until sampling ends.
            commandBuffer.addCompletedHandler { [frame] _ in _ = frame }
            lock.lock()
            diagnostics = MetalPresentationDiagnostics(
                scalingStatus: opacity < 1 ? .transition : scalingStatus,
                sourceSize: frame.dimensions, pictureSize: pictureSize, drawableSize: size,
                dynamicRangeMode: state.dynamicRangeMode == .extendedDynamicRange ? .extendedDynamicRange : .standardDynamicRange
            )
            lock.unlock()
            lastPresentationOpacity = opacity
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }

    private func renderPass(texture: MTLTexture) -> MTLRenderPassDescriptor {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        return descriptor
    }

    private func encodeFrame(_ frame: MetalPresentedFrame, state: RenderState,
                             encoder: MTLRenderCommandEncoder, scale: SIMD2<Float>) {
        var presentation = MetalPresentationUniform(scale: scale)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&presentation, length: MemoryLayout<MetalPresentationUniform>.stride, index: 1)
        switch frame.textures {
        case .rgb(let texture):
            encoder.setRenderPipelineState(state.rgbPipelineState)
            encoder.setFragmentTexture(texture, index: 0)
        case .biPlanar(let luma, let chroma):
            encoder.setRenderPipelineState(state.biPlanarPipelineState)
            encoder.setFragmentTexture(luma, index: 0)
            encoder.setFragmentTexture(chroma, index: 1)
            var conversion = frame.colorConversion.makeShaderUniform(outputEncoding: state.dynamicRangeMode.colorOutputEncoding)
            encoder.setFragmentBytes(&conversion, length: MemoryLayout<MetalColorConversionUniform>.stride, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    private func convertedTexture(frame: MetalPresentedFrame, state: RenderState,
                                  commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        let source: MTLTexture
        switch frame.textures {
        case .rgb(let texture): source = texture
        case .biPlanar(let luma, _): source = luma
        }
        let width = source.width
        let height = source.height
        guard width > 0, height > 0, width <= 16384, height <= 16384 else { return nil }
        let format = state.dynamicRangeMode.drawablePixelFormat
        if colorTexture?.width != width || colorTexture?.height != height || colorTexture?.pixelFormat != format {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
                width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            colorTexture = device.makeTexture(descriptor: descriptor)
        }
        guard let texture = colorTexture,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass(texture: texture)) else { return nil }
        encodeFrame(frame, state: state, encoder: encoder, scale: SIMD2(1, 1))
        encoder.endEncoding()
        return texture
    }

    private func upscaledTexture(color: MTLTexture, frame: MetalPresentedFrame, size: CGSize,
                                 state: RenderState, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        #if canImport(MetalFX)
        guard upscalingMode == .metalFXSpatial, MTLFXSpatialScalerDescriptor.supportsDevice(device) else { return nil }
        let geometry = MetalPresentationGeometry(contentMode: contentMode, frameDimensions: frame.dimensions, drawableSize: size)
        let pictureSize = geometry.pictureSize
        guard pictureSize.width.isFinite, pictureSize.height.isFinite,
              pictureSize.width > 0, pictureSize.height > 0,
              pictureSize.width <= 16384, pictureSize.height <= 16384 else { return nil }
        let width = Int(pictureSize.width.rounded(.up))
        let height = Int(pictureSize.height.rounded(.up))
        guard width >= color.width, height >= color.height,
              width > color.width || height > color.height,
              width <= 16384, height <= 16384 else { return nil }
        if spatialUpscaler?.matches(input: color, width: width, height: height) != true {
            spatialUpscaler = MetalSpatialUpscaler(device: device, input: color,
                width: width, height: height, hdr: state.dynamicRangeMode == .extendedDynamicRange)
        }
        return spatialUpscaler?.encode(input: color, commandBuffer: commandBuffer)
        #else
        return nil
        #endif
    }

}

extension MTLDevice {
    func makeDefaultSwiftMoonlightLibrary() throws -> MTLLibrary {
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOut {
            float4 position [[position]];
            float2 texCoord;
        };

        struct ColorConversionUniform {
            float4 offsets;
            float4 scales;
            float4 matrixR;
            float4 matrixG;
            float4 matrixB;
            uint transferFunction;
            uint ycbcrMatrix;
            uint outputEncoding;
            uint padding1;
        };

        struct PresentationUniform {
            float2 scale;
        };

        vertex VertexOut vertexMain(
            uint vertexID [[vertex_id]],
            const device float4* vertices [[buffer(0)]],
            constant PresentationUniform& presentation [[buffer(1)]]
        ) {
            VertexOut out;
            float4 entry = vertices[vertexID];
            out.position = float4(entry.xy * presentation.scale, 0.0, 1.0);
            out.texCoord = entry.zw;
            return out;
        }

        fragment float4 fragmentRGB(VertexOut in [[stage_in]], texture2d<float> colorTexture [[texture(0)]]) {
            if (any(in.texCoord < 0.0) || any(in.texCoord > 1.0)) { discard_fragment(); }
            constexpr sampler textureSampler(address::clamp_to_edge, mag_filter::linear, min_filter::linear);
            return colorTexture.sample(textureSampler, in.texCoord);
        }


        fragment float4 fragmentPresentation(
            VertexOut in [[stage_in]], texture2d<float> picture [[texture(0)]],
            texture2d<float> background [[texture(1)]],
            constant float4& effect [[buffer(0)]], constant float2& backgroundScale [[buffer(1)]]
        ) {
            constexpr sampler s(address::clamp_to_edge, mag_filter::linear, min_filter::linear);
            float2 uv = (in.texCoord - 0.5) / effect.xy + 0.5;
            bool inside = all(uv >= 0.0) && all(uv <= 1.0);
            float4 sharp = inside ? picture.sample(s, uv) : float4(0.0, 0.0, 0.0, 1.0);
            if (effect.w == 0.0 || (inside && effect.z == 1.0)) { return sharp; }
            float2 bgUV = (in.texCoord - 0.5) / backgroundScale + 0.5;
            float4 blurred = background.sample(s, bgUV);
            blurred.rgb *= mix(0.25, 0.12, smoothstep(0.0, 1.0, in.texCoord.y));
            blurred.a = 1.0;
            return mix(blurred, sharp, inside ? effect.z : 0.0);
        }

        float3 linearToSRGB(float3 linear) {
            linear = max(linear, float3(0.0));
            float3 low = linear * 12.92;
            float3 high = 1.055 * pow(linear, float3(1.0 / 2.4)) - 0.055;
            return select(high, low, linear <= float3(0.0031308));
        }

        float3 srgbToLinear(float3 srgb) {
            srgb = saturate(srgb);
            float3 low = srgb / 12.92;
            float3 high = pow((srgb + 0.055) / 1.055, float3(2.4));
            return select(high, low, srgb <= float3(0.04045));
        }

        float3 bt2020LinearToBT709Linear(float3 rgb) {
            // PQ decode produces linear BT.2020 for HDR streams, but the
            // current layer target is SDR BGRA. Convert gamut before encoding.
            return float3(
                dot(float3(1.6605, -0.5876, -0.0728), rgb),
                dot(float3(-0.1246, 1.1329, -0.0083), rgb),
                dot(float3(-0.0182, -0.1006, 1.1187), rgb)
            );
        }

        float3 toneMapHDRToSDR(float3 nits) {
            // Preserve SDR-range values while rolling off HDR highlights
            // instead of clipping all content above reference white.
            float3 reference = max(nits / 203.0, float3(0.0));
            float3 linearRegion = reference * 0.78;
            float3 shoulder = 0.78 + 0.22 * (1.0 - exp(-(reference - 1.0) * 0.35));
            return min(select(shoulder, linearRegion, reference <= float3(1.0)), float3(1.0));
        }

        float3 pqToSRGB(float3 pq, uint ycbcrMatrix) {
            constexpr float m1 = 2610.0 / 16384.0;
            constexpr float m2 = 2523.0 / 32.0;
            constexpr float c1 = 3424.0 / 4096.0;
            constexpr float c2 = 2413.0 / 128.0;
            constexpr float c3 = 2392.0 / 128.0;
            pq = clamp(pq, float3(0.0), float3(1.0));
            float3 p = pow(pq, float3(1.0 / m2));
            float3 numerator = max(p - c1, float3(0.0));
            float3 denominator = max(c2 - c3 * p, float3(0.000001));
            float3 nits = pow(numerator / denominator, float3(1.0 / m1)) * 10000.0;
            if (ycbcrMatrix == 1) {
                nits = bt2020LinearToBT709Linear(nits);
            }
            return linearToSRGB(toneMapHDRToSDR(nits));
        }

        float3 pqToExtendedLinearSRGB(float3 pq, uint ycbcrMatrix) {
            constexpr float m1 = 2610.0 / 16384.0;
            constexpr float m2 = 2523.0 / 32.0;
            constexpr float c1 = 3424.0 / 4096.0;
            constexpr float c2 = 2413.0 / 128.0;
            constexpr float c3 = 2392.0 / 128.0;
            pq = clamp(pq, float3(0.0), float3(1.0));
            float3 p = pow(pq, float3(1.0 / m2));
            float3 numerator = max(p - c1, float3(0.0));
            float3 denominator = max(c2 - c3 * p, float3(0.000001));
            float3 nits = pow(numerator / denominator, float3(1.0 / m1)) * 10000.0;
            if (ycbcrMatrix == 1) {
                nits = bt2020LinearToBT709Linear(nits);
            }
            return max(nits / 203.0, float3(0.0));
        }

        float3 hlgToSRGB(float3 hlg, uint ycbcrMatrix) {
            constexpr float a = 0.17883277;
            constexpr float b = 0.28466892;
            constexpr float c = 0.55991073;
            hlg = clamp(hlg, float3(0.0), float3(1.0));
            float3 low = (hlg * hlg) / 3.0;
            float3 high = (exp((hlg - c) / a) + b) / 12.0;
            float3 sceneLinear = select(high, low, hlg <= float3(0.5));
            float3 nits = sceneLinear * 1000.0;
            if (ycbcrMatrix == 1) {
                nits = bt2020LinearToBT709Linear(nits);
            }
            return linearToSRGB(toneMapHDRToSDR(nits));
        }

        float3 hlgToExtendedLinearSRGB(float3 hlg, uint ycbcrMatrix) {
            constexpr float a = 0.17883277;
            constexpr float b = 0.28466892;
            constexpr float c = 0.55991073;
            hlg = clamp(hlg, float3(0.0), float3(1.0));
            float3 low = (hlg * hlg) / 3.0;
            float3 high = (exp((hlg - c) / a) + b) / 12.0;
            float3 sceneLinear = select(high, low, hlg <= float3(0.5));
            float3 nits = sceneLinear * 1000.0;
            if (ycbcrMatrix == 1) {
                nits = bt2020LinearToBT709Linear(nits);
            }
            return max(nits / 203.0, float3(0.0));
        }

        fragment float4 fragmentBiPlanar(
            VertexOut in [[stage_in]],
            texture2d<float> lumaTexture [[texture(0)]],
            texture2d<float> chromaTexture [[texture(1)]],
            constant ColorConversionUniform& conversion [[buffer(0)]]
        ) {
            if (any(in.texCoord < 0.0) || any(in.texCoord > 1.0)) { discard_fragment(); }
            constexpr sampler textureSampler(address::clamp_to_edge, mag_filter::linear, min_filter::linear);
            float y = (lumaTexture.sample(textureSampler, in.texCoord).r - conversion.offsets.x) * conversion.scales.x;
            float2 cbcr = (chromaTexture.sample(textureSampler, in.texCoord).rg - conversion.offsets.yz) * conversion.scales.yz;
            float3 ycbcr = float3(y, cbcr.x, cbcr.y);

            float3 rgb = float3(
                dot(conversion.matrixR.xyz, ycbcr),
                dot(conversion.matrixG.xyz, ycbcr),
                dot(conversion.matrixB.xyz, ycbcr)
            );

            if (conversion.transferFunction == 1) {
                rgb = conversion.outputEncoding == 1
                    ? pqToExtendedLinearSRGB(rgb, conversion.ycbcrMatrix)
                    : pqToSRGB(rgb, conversion.ycbcrMatrix);
            } else if (conversion.transferFunction == 2) {
                rgb = conversion.outputEncoding == 1
                    ? hlgToExtendedLinearSRGB(rgb, conversion.ycbcrMatrix)
                    : hlgToSRGB(rgb, conversion.ycbcrMatrix);
            } else if (conversion.outputEncoding == 1) {
                rgb = srgbToLinear(rgb);
            }

            if (conversion.outputEncoding == 1) {
                return float4(max(rgb, float3(0.0)), 1.0);
            }
            return float4(saturate(rgb), 1.0);
        }
        """

        do {
            return try makeLibrary(source: source, options: nil)
        } catch {
            throw MoonlightError(.unsupportedOperation, message: "Failed to compile Metal shader library: \(error)")
        }
    }
}
#endif
