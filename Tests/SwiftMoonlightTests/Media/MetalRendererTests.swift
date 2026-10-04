#if canImport(Metal) && canImport(CoreVideo)
import CoreGraphics
import CoreVideo
import Metal
import QuartzCore
import Testing
@testable import SwiftMoonlight

private actor RecordingMetalTarget: MetalFrameTarget {
    private(set) var preparedFormats: [VideoFormat] = []
    private(set) var frames: [MetalPresentedFrame] = []
    private(set) var teardownCount = 0

    func prepare(format: VideoFormat) async throws {
        preparedFormats.append(format)
    }

    func present(_ frame: MetalPresentedFrame) async {
        frames.append(frame)
    }

    func teardown() async {
        teardownCount += 1
    }

    func snapshot() -> (preparedFormats: [VideoFormat], frames: [MetalPresentedFrame], teardownCount: Int) {
        (preparedFormats, frames, teardownCount)
    }
}

@Test
func metalDisplayPresenterKeepsNewestDecodedFrame() throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vertices = device.makeBuffer(length: 16, options: []) else { return }
    let presenter = MetalDisplayPresenter(
        commandQueue: queue, vertexBuffer: vertices, contentMode: .stretch, preferredFrameRate: 120,
        device: device,
        upscalingMode: .linear, background: .black
    )
    let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false
    )
    guard let texture = device.makeTexture(descriptor: textureDescriptor) else { return }
    presenter.enqueue(MetalPresentedFrame(timestamp: 1, dimensions: CGSize(width: 1, height: 1), textures: .rgb(texture)))
    presenter.enqueue(MetalPresentedFrame(timestamp: 2, dimensions: CGSize(width: 1, height: 1), textures: .rgb(texture)))
    #expect(presenter.takePendingFrame().frame?.timestamp == 2)
    let retained = presenter.takePendingFrame()
    #expect(retained.frame?.timestamp == 2)
    #expect(retained.fresh == false)
    presenter.beginTransition()
    #expect(presenter.takePendingFrame().opacity == 0)
    // Frames from the old stream cannot end the restart transition.
    presenter.enqueue(MetalPresentedFrame(timestamp: 3, dimensions: CGSize(width: 1, height: 1), textures: .rgb(texture)))
    #expect(presenter.takePendingFrame().opacity == 0)
    let library = try device.makeDefaultSwiftMoonlightLibrary()
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "vertexMain")
    descriptor.fragmentFunction = library.makeFunction(name: "fragmentRGB")
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    presenter.configure(rgbPipelineState: pipeline, biPlanarPipelineState: pipeline,
        presentationPipelineState: pipeline, dynamicRangeMode: .standardDynamicRange)
    #expect(presenter.takePendingFrame().opacity == 0)
    presenter.enqueue(MetalPresentedFrame(timestamp: 4, dimensions: CGSize(width: 1, height: 1), textures: .rgb(texture)))
    #expect(presenter.takePendingFrame().frame?.timestamp == 4)
    #expect(presenter.takePendingFrame(at: CACurrentMediaTime() + 1).opacity == 1)
    presenter.beginTransition()
    presenter.endTransition()
    #expect(presenter.takePendingFrame(at: CACurrentMediaTime() + 1).opacity == 1)
}

@Test
func metalRendererPresentsRGBPixelBufferFrames() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
        return
    }

    let target = RecordingMetalTarget()
    let renderer = try MetalRenderer(device: device, target: target)
    let format = VideoFormat(codec: .h264, dimensions: CGSize(width: 1280, height: 720))

    try await renderer.prepare(format: format)

    let pixelBuffer = try makePixelBuffer(width: 128, height: 72, pixelFormat: kCVPixelFormatType_32BGRA)
    await renderer.render(
        DecodedVideoFrame(
            timestamp: 42,
            dimensions: format.dimensions,
            pixelBuffer: PixelBufferBox(pixelBuffer)
        )
    )

    let snapshot = await target.snapshot()
    #expect(snapshot.preparedFormats == [format])
    #expect(snapshot.frames.count == 1)
    #expect(snapshot.frames[0].timestamp == 42)
    #expect(snapshot.frames[0].dimensions == format.dimensions)
    #expect(snapshot.frames[0].retainedResources?.retainedObjects.isEmpty == false)

    switch snapshot.frames[0].textures {
    case .rgb(let texture):
        #expect(texture.width == 128)
        #expect(texture.height == 72)
        #expect(texture.pixelFormat == .bgra8Unorm)
    case .biPlanar:
        Issue.record("Expected an RGB texture for BGRA pixel buffers")
    }
}

@Test
func metalRendererTeardownFlushesTarget() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
        return
    }

    let target = RecordingMetalTarget()
    let renderer = try MetalRenderer(device: device, target: target)
    try await renderer.prepare(format: VideoFormat(codec: .h264, dimensions: CGSize(width: 1920, height: 1080)))

    await renderer.teardown()

    let snapshot = await target.snapshot()
    #expect(snapshot.teardownCount == 1)
}

@Test
func metalRendererPresentsCompressedBiPlanarVideoRangeFrames() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
        return
    }
    guard CVIsCompressedPixelFormatAvailable(kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange) else {
        return
    }

    let target = RecordingMetalTarget()
    let renderer = try MetalRenderer(device: device, target: target)
    let format = VideoFormat(codec: .hevc, dimensions: CGSize(width: 1920, height: 1080))

    try await renderer.prepare(format: format)

    let pixelBuffer = try makePixelBuffer(
        width: 128,
        height: 72,
        pixelFormat: kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange
    )
    await renderer.render(
        DecodedVideoFrame(
            timestamp: 7,
            dimensions: format.dimensions,
            pixelBuffer: PixelBufferBox(pixelBuffer)
        )
    )

    let snapshot = await target.snapshot()
    #expect(snapshot.frames.count == 1)
    #expect(snapshot.frames[0].colorConversion == .sdrBT709VideoRange8)

    switch snapshot.frames[0].textures {
    case .rgb:
        Issue.record("Expected a bi-planar texture pair for compressed NV12 pixel buffers")
    case .biPlanar(let luma, let chroma):
        #expect(luma.pixelFormat == .r8Unorm)
        #expect(chroma.pixelFormat == .rg8Unorm)
    }
}

@Test
func metalRendererCarriesHDRBiPlanarColorMetadata() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
        return
    }

    let target = RecordingMetalTarget()
    let renderer = try MetalRenderer(device: device, target: target)
    let format = VideoFormat(codec: .hevc, dimensions: CGSize(width: 1920, height: 1080), dynamicRange: .hdr)

    try await renderer.prepare(format: format)

    let pixelBuffer: CVPixelBuffer
    do {
        pixelBuffer = try makePixelBuffer(
            width: 128,
            height: 72,
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
    } catch {
        return
    }
    CVBufferSetAttachment(
        pixelBuffer,
        kCVImageBufferTransferFunctionKey,
        kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
        .shouldPropagate
    )
    CVBufferSetAttachment(
        pixelBuffer,
        kCVImageBufferYCbCrMatrixKey,
        kCVImageBufferYCbCrMatrix_ITU_R_2020,
        .shouldPropagate
    )

    await renderer.render(
        DecodedVideoFrame(
            timestamp: 8,
            dimensions: format.dimensions,
            pixelBuffer: PixelBufferBox(pixelBuffer)
        )
    )

    let snapshot = await target.snapshot()
    #expect(snapshot.frames.count == 1)
    #expect(snapshot.frames[0].colorConversion == MetalColorConversion(
        transferFunction: .pq,
        ycbcrRange: .video,
        ycbcrMatrix: .bt2020,
        componentBitDepth: 10
    ))

    switch snapshot.frames[0].textures {
    case .rgb:
        Issue.record("Expected a bi-planar texture pair for HDR 10-bit pixel buffers")
    case .biPlanar(let luma, let chroma):
        #expect(luma.pixelFormat == .r16Unorm)
        #expect(chroma.pixelFormat == .rg16Unorm)
    }
}

@Test
func metalRendererCarriesHLGBiPlanarColorMetadata() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
        return
    }

    let target = RecordingMetalTarget()
    let renderer = try MetalRenderer(device: device, target: target)
    let format = VideoFormat(codec: .hevc, dimensions: CGSize(width: 1920, height: 1080), dynamicRange: .hdr)

    try await renderer.prepare(format: format)

    let pixelBuffer: CVPixelBuffer
    do {
        pixelBuffer = try makePixelBuffer(
            width: 128,
            height: 72,
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
    } catch {
        return
    }
    CVBufferSetAttachment(
        pixelBuffer,
        kCVImageBufferTransferFunctionKey,
        kCVImageBufferTransferFunction_ITU_R_2100_HLG,
        .shouldPropagate
    )
    CVBufferSetAttachment(
        pixelBuffer,
        kCVImageBufferYCbCrMatrixKey,
        kCVImageBufferYCbCrMatrix_ITU_R_2020,
        .shouldPropagate
    )

    await renderer.render(
        DecodedVideoFrame(
            timestamp: 10,
            dimensions: format.dimensions,
            pixelBuffer: PixelBufferBox(pixelBuffer)
        )
    )

    let snapshot = await target.snapshot()
    #expect(snapshot.frames.count == 1)
    #expect(snapshot.frames[0].colorConversion == MetalColorConversion(
        transferFunction: .hlg,
        ycbcrRange: .video,
        ycbcrMatrix: .bt2020,
        componentBitDepth: 10
    ))
}

@Test
func metalRendererHonorsBT601ColorAttachment() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
        return
    }

    let target = RecordingMetalTarget()
    let renderer = try MetalRenderer(device: device, target: target)
    let format = VideoFormat(codec: .hevc, dimensions: CGSize(width: 1920, height: 1080))

    try await renderer.prepare(format: format)

    let pixelBuffer = try makePixelBuffer(
        width: 128,
        height: 72,
        pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    )
    CVBufferSetAttachment(
        pixelBuffer,
        kCVImageBufferYCbCrMatrixKey,
        kCVImageBufferYCbCrMatrix_ITU_R_601_4,
        .shouldPropagate
    )

    await renderer.render(
        DecodedVideoFrame(
            timestamp: 9,
            dimensions: format.dimensions,
            pixelBuffer: PixelBufferBox(pixelBuffer)
        )
    )

    let snapshot = await target.snapshot()
    #expect(snapshot.frames.count == 1)
    #expect(snapshot.frames[0].colorConversion.ycbcrMatrix == .bt601)
}

@Test
func metalRendererDoesNotInferBT2020FromHDRRequestWhenFrameTransferIsSDR() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
        return
    }

    let target = RecordingMetalTarget()
    let renderer = try MetalRenderer(device: device, target: target)
    let format = VideoFormat(codec: .hevc, dimensions: CGSize(width: 1920, height: 1080), dynamicRange: .hdr)

    try await renderer.prepare(format: format)

    let pixelBuffer: CVPixelBuffer
    do {
        pixelBuffer = try makePixelBuffer(
            width: 128,
            height: 72,
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
    } catch {
        return
    }
    CVBufferSetAttachment(
        pixelBuffer,
        kCVImageBufferTransferFunctionKey,
        kCVImageBufferTransferFunction_ITU_R_709_2,
        .shouldPropagate
    )

    await renderer.render(
        DecodedVideoFrame(
            timestamp: 11,
            dimensions: format.dimensions,
            pixelBuffer: PixelBufferBox(pixelBuffer)
        )
    )

    let snapshot = await target.snapshot()
    #expect(snapshot.frames.count == 1)
    #expect(snapshot.frames[0].colorConversion.transferFunction == .sdr)
    #expect(snapshot.frames[0].colorConversion.ycbcrMatrix == .bt709)
}

@Test
func metalColorConversionUniformAppliesVideoRangeScalingAndMatrix() {
    let uniform = MetalColorConversion.sdrBT709VideoRange8.makeShaderUniform()

    #expect(approximatelyEqual(uniform.offsets.x, 16.0 / 255.0))
    #expect(approximatelyEqual(uniform.offsets.y, 128.0 / 255.0))
    #expect(approximatelyEqual(uniform.scales.x, 255.0 / 219.0))
    #expect(approximatelyEqual(uniform.scales.y, 255.0 / 224.0))
    #expect(approximatelyEqual(uniform.matrixR.z, 1.5748))
    #expect(approximatelyEqual(uniform.matrixG.y, -0.187324))
    #expect(uniform.transferFunction == MetalColorConversion.TransferFunction.sdr.rawValue)
    #expect(uniform.outputEncoding == MetalColorOutputEncoding.sdrSRGB.rawValue)
}

@Test
func metalColorConversionUniformUsesTenBitHDRRanges() {
    let uniform = MetalColorConversion(
        transferFunction: .pq,
        ycbcrRange: .video,
        ycbcrMatrix: .bt2020,
        componentBitDepth: 10
    ).makeShaderUniform()

    #expect(approximatelyEqual(uniform.offsets.x, 64.0 / 1023.0))
    #expect(approximatelyEqual(uniform.offsets.y, 512.0 / 1023.0))
    #expect(approximatelyEqual(uniform.scales.x, 1023.0 / 876.0))
    #expect(approximatelyEqual(uniform.scales.y, 1023.0 / 896.0))
    #expect(approximatelyEqual(uniform.matrixR.z, 1.4746))
    #expect(uniform.transferFunction == MetalColorConversion.TransferFunction.pq.rawValue)
    #expect(uniform.ycbcrMatrix == MetalColorConversion.YCbCrMatrix.bt2020.rawValue)
    #expect(uniform.outputEncoding == MetalColorOutputEncoding.sdrSRGB.rawValue)
    #expect(MemoryLayout<MetalColorConversionUniform>.stride == 96)
}

@Test
func metalColorConversionUniformCarriesExtendedLinearOutputEncoding() {
    let uniform = MetalColorConversion(
        transferFunction: .pq,
        ycbcrRange: .video,
        ycbcrMatrix: .bt2020,
        componentBitDepth: 10
    ).makeShaderUniform(outputEncoding: .extendedLinearSRGB)

    #expect(uniform.outputEncoding == MetalColorOutputEncoding.extendedLinearSRGB.rawValue)
    #expect(MemoryLayout<MetalColorConversionUniform>.stride == 96)
}

@Test
func metalColorConversionUniformCarriesHLGTransferFunction() {
    let uniform = MetalColorConversion(
        transferFunction: .hlg,
        ycbcrRange: .video,
        ycbcrMatrix: .bt2020,
        componentBitDepth: 10
    ).makeShaderUniform()

    #expect(uniform.transferFunction == MetalColorConversion.TransferFunction.hlg.rawValue)
    #expect(uniform.ycbcrMatrix == MetalColorConversion.YCbCrMatrix.bt2020.rawValue)
}

private func makePixelBuffer(width: Int, height: Int, pixelFormat: OSType) throws -> CVPixelBuffer {
    let attributes: NSDictionary = [
        kCVPixelBufferMetalCompatibilityKey: true,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary
    ]

    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        pixelFormat,
        attributes,
        &pixelBuffer
    )

    guard status == kCVReturnSuccess, let pixelBuffer else {
        throw MoonlightError(.unsupportedOperation, message: "Failed to create test pixel buffer: \(status)")
    }

    return pixelBuffer
}

private func approximatelyEqual(_ lhs: Float, _ rhs: Float, tolerance: Float = 0.0001) -> Bool {
    abs(lhs - rhs) <= tolerance
}
#endif
