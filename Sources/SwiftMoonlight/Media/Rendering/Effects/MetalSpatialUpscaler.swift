#if canImport(MetalFX)
import Metal
import MetalFX

/// The serial display callback owns this object. The command queue orders texture access.
final class MetalSpatialUpscaler {
    private let scaler: any MTLFXSpatialScaler
    private let output: any MTLTexture

    init?(device: any MTLDevice, input: any MTLTexture, width: Int, height: Int, hdr: Bool) {
        guard MTLFXSpatialScalerDescriptor.supportsDevice(device) else { return nil }
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = input.width
        descriptor.inputHeight = input.height
        descriptor.outputWidth = width
        descriptor.outputHeight = height
        descriptor.colorTextureFormat = input.pixelFormat
        descriptor.outputTextureFormat = input.pixelFormat
        descriptor.colorProcessingMode = hdr ? .hdr : .perceptual
        guard let scaler = descriptor.makeSpatialScaler(device: device) else { return nil }
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: input.pixelFormat,
            width: width, height: height, mipmapped: false)
        textureDescriptor.storageMode = .private
        textureDescriptor.usage = scaler.outputTextureUsage.union(.shaderRead)
        guard let output = device.makeTexture(descriptor: textureDescriptor) else { return nil }
        self.scaler = scaler
        self.output = output
    }

    func matches(input: any MTLTexture, width: Int, height: Int) -> Bool {
        scaler.inputWidth == input.width && scaler.inputHeight == input.height &&
        output.width == width && output.height == height && output.pixelFormat == input.pixelFormat
    }

    func encode(input: any MTLTexture, commandBuffer: any MTLCommandBuffer) -> (any MTLTexture)? {
        guard input.usage.contains(scaler.colorTextureUsage) else { return nil }
        scaler.colorTexture = input
        scaler.outputTexture = output
        scaler.encode(commandBuffer: commandBuffer)
        return output
    }
}
#endif
