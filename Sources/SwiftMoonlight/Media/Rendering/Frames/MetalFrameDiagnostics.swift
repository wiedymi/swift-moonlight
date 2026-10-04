#if canImport(Metal) && canImport(CoreVideo)
import CoreGraphics
import CoreVideo
import Foundation
import Metal

public struct MetalFrameDiagnostics: Sendable, Equatable {
    public let dimensions: CGSize
    public let pixelFormat: UInt32
    public let pixelFormatName: String
    public let planeCount: Int
    public let colorConversion: MetalColorConversion
    public let attachments: [String: String]

    public init(
        dimensions: CGSize,
        pixelFormat: UInt32,
        pixelFormatName: String,
        planeCount: Int,
        colorConversion: MetalColorConversion,
        attachments: [String: String]
    ) {
        self.dimensions = dimensions
        self.pixelFormat = pixelFormat
        self.pixelFormatName = pixelFormatName
        self.planeCount = planeCount
        self.colorConversion = colorConversion
        self.attachments = attachments
    }

    public var summary: String {
        let attachmentSummary = attachments
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
        let conversionSummary = "range=\(colorConversion.ycbcrRange) matrix=\(colorConversion.ycbcrMatrix) transfer=\(colorConversion.transferFunction) depth=\(colorConversion.componentBitDepth)"
        let base = "\(Int(dimensions.width))x\(Int(dimensions.height)) \(pixelFormatName) planes=\(planeCount) \(conversionSummary)"
        return attachmentSummary.isEmpty ? base : "\(base) attachments: \(attachmentSummary)"
    }
}
#endif
