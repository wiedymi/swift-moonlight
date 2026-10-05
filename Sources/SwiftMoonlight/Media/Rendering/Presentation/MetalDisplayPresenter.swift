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
        #if os(macOS)
        if let preferredFrameRate {
            let preferred = Float(min(max(preferredFrameRate, 1), 240))
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: min(preferred, 30), maximum: preferred, preferred: preferred
            )
        }
        #endif
        link.delegate = self
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @MainActor func setPreferredFrameRate(_ rate: Int) {
        let rate = min(max(rate, 1), 240)
        preferredFrameRate = rate
        displayLink?.preferredFrameRateRange = CAFrameRateRange(
            minimum: Float(min(rate, 30)), maximum: Float(rate), preferred: Float(rate)
        )
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

        guard let frame = pending.frame, let state = pending.state else { return }
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
            guard pending.fresh || resized || opacity != lastPresentationOpacity,
                  let commandBuffer = commandQueue.makeCommandBuffer() else { return }
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
#endif
