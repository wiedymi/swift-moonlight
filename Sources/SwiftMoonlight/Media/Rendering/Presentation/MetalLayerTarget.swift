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
#endif
