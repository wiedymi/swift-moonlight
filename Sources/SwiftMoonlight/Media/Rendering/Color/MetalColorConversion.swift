#if canImport(Metal) && canImport(CoreVideo)
import CoreGraphics
import CoreVideo
import Foundation
import Metal

public struct MetalColorConversion: Sendable, Equatable {
    public enum TransferFunction: UInt32, Sendable {
        case sdr = 0
        case pq = 1
        case hlg = 2
    }

    public enum YCbCrRange: UInt32, Sendable {
        case full = 0
        case video = 1
    }

    public enum YCbCrMatrix: UInt32, Sendable {
        case bt709 = 0
        case bt2020 = 1
        case bt601 = 2
    }

    public var transferFunction: TransferFunction
    public var ycbcrRange: YCbCrRange
    public var ycbcrMatrix: YCbCrMatrix
    public var componentBitDepth: UInt32

    public init(
        transferFunction: TransferFunction,
        ycbcrRange: YCbCrRange,
        ycbcrMatrix: YCbCrMatrix,
        componentBitDepth: UInt32
    ) {
        self.transferFunction = transferFunction
        self.ycbcrRange = ycbcrRange
        self.ycbcrMatrix = ycbcrMatrix
        self.componentBitDepth = componentBitDepth
    }

    public static let sdrBT709VideoRange8 = MetalColorConversion(
        transferFunction: .sdr,
        ycbcrRange: .video,
        ycbcrMatrix: .bt709,
        componentBitDepth: 8
    )
}

struct MetalColorConversionUniform: Sendable, Equatable {
    var offsets: SIMD4<Float>
    var scales: SIMD4<Float>
    var matrixR: SIMD4<Float>
    var matrixG: SIMD4<Float>
    var matrixB: SIMD4<Float>
    var transferFunction: UInt32
    var ycbcrMatrix: UInt32
    var outputEncoding: UInt32
    var padding1: UInt32 = 0
}

enum MetalColorOutputEncoding: UInt32, Sendable {
    case sdrSRGB = 0
    case extendedLinearSRGB = 1
}

extension MetalColorConversion {
    func makeShaderUniform(
        outputEncoding: MetalColorOutputEncoding = .sdrSRGB
    ) -> MetalColorConversionUniform {
        let maxCodeValue: Float = componentBitDepth == 10 ? 1023 : 255
        let videoRange = ycbcrRange == .video

        let yOffset: Float
        let yScale: Float
        let chromaOffset: Float
        let chromaScale: Float
        if videoRange {
            if componentBitDepth == 10 {
                yOffset = 64 / maxCodeValue
                yScale = maxCodeValue / (940 - 64)
                chromaOffset = 512 / maxCodeValue
                chromaScale = maxCodeValue / (960 - 64)
            } else {
                yOffset = 16 / maxCodeValue
                yScale = maxCodeValue / (235 - 16)
                chromaOffset = 128 / maxCodeValue
                chromaScale = maxCodeValue / (240 - 16)
            }
        } else {
            yOffset = 0
            yScale = 1
            chromaOffset = 0.5
            chromaScale = 1
        }

        let rows: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
        switch ycbcrMatrix {
        case .bt601:
            rows = (
                SIMD4<Float>(1.0, 0.0, 1.4020, 0.0),
                SIMD4<Float>(1.0, -0.344136, -0.714136, 0.0),
                SIMD4<Float>(1.0, 1.7720, 0.0, 0.0)
            )
        case .bt709:
            rows = (
                SIMD4<Float>(1.0, 0.0, 1.5748, 0.0),
                SIMD4<Float>(1.0, -0.187324, -0.468124, 0.0),
                SIMD4<Float>(1.0, 1.8556, 0.0, 0.0)
            )
        case .bt2020:
            rows = (
                SIMD4<Float>(1.0, 0.0, 1.4746, 0.0),
                SIMD4<Float>(1.0, -0.164553, -0.571353, 0.0),
                SIMD4<Float>(1.0, 1.8814, 0.0, 0.0)
            )
        }

        return MetalColorConversionUniform(
            offsets: SIMD4<Float>(yOffset, chromaOffset, chromaOffset, 0),
            scales: SIMD4<Float>(yScale, chromaScale, chromaScale, 1),
            matrixR: rows.0,
            matrixG: rows.1,
            matrixB: rows.2,
            transferFunction: transferFunction.rawValue,
            ycbcrMatrix: ycbcrMatrix.rawValue,
            outputEncoding: outputEncoding.rawValue
        )
    }
}
#endif
