#if canImport(Metal) && canImport(CoreVideo)
import CoreGraphics
import CoreVideo
import Foundation
import Metal

public enum MetalTexturePlanes: @unchecked Sendable {
    case rgb(MTLTexture)
    case biPlanar(luma: MTLTexture, chroma: MTLTexture)
}

public final class MetalPresentedFrame: @unchecked Sendable {
    public let timestamp: UInt64
    public let dimensions: CGSize
    public let textures: MetalTexturePlanes
    public let colorConversion: MetalColorConversion
    public let retainedResources: MetalFrameResources?

    public init(
        timestamp: UInt64,
        dimensions: CGSize,
        textures: MetalTexturePlanes,
        colorConversion: MetalColorConversion = .sdrBT709VideoRange8,
        retainedResources: MetalFrameResources? = nil
    ) {
        self.timestamp = timestamp
        self.dimensions = dimensions
        self.textures = textures
        self.colorConversion = colorConversion
        self.retainedResources = retainedResources
    }
}
#endif
