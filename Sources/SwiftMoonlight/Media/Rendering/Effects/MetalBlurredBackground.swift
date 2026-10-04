#if canImport(MetalPerformanceShaders)
import Metal
import MetalPerformanceShaders

/// The serial display callback owns the textures; its queue orders all access.
final class MetalBlurredBackground {
    private let input: any MTLTexture
    let output: any MTLTexture
    private weak var sourceFrame: MetalPresentedFrame?
    private let blur: MPSImageGaussianBlur

    init?(device: any MTLDevice, source: any MTLTexture) {
        let ratio = min(256.0 / Double(max(source.width, source.height)), 1)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: source.pixelFormat,
            width: max(Int((Double(source.width) * ratio).rounded()), 1),
            height: max(Int((Double(source.height) * ratio).rounded()), 1), mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        guard let input = device.makeTexture(descriptor: descriptor),
              let output = device.makeTexture(descriptor: descriptor) else { return nil }
        self.input = input
        self.output = output
        blur = MPSImageGaussianBlur(device: device, sigma: 16)
        blur.edgeMode = .clamp
    }

    func matches(source: any MTLTexture) -> Bool {
        let ratio = min(256.0 / Double(max(source.width, source.height)), 1)
        return input.pixelFormat == source.pixelFormat &&
            input.width == max(Int((Double(source.width) * ratio).rounded()), 1) &&
            input.height == max(Int((Double(source.height) * ratio).rounded()), 1)
    }

    func encode(source: any MTLTexture, frame: MetalPresentedFrame? = nil, pipeline: any MTLRenderPipelineState,
                vertices: any MTLBuffer, commandBuffer: any MTLCommandBuffer) -> (any MTLTexture)? {
        if let frame, sourceFrame === frame { return output }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = input
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var presentation = MetalPresentationUniform(scale: SIMD2(1, 1))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vertices, offset: 0, index: 0)
        encoder.setVertexBytes(&presentation, length: MemoryLayout<MetalPresentationUniform>.stride, index: 1)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        blur.encode(commandBuffer: commandBuffer, sourceTexture: input, destinationTexture: output)
        sourceFrame = frame
        return output
    }
}
#endif
