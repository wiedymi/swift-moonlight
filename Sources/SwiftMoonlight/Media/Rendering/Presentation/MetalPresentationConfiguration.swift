#if canImport(Metal) && canImport(QuartzCore)
import CoreGraphics
import Foundation
import Metal
import QuartzCore

public enum MetalPresentationContentMode: Sendable, Equatable {
    case stretch
    case aspectFit
    case aspectFill
}

public enum MetalPresentationDynamicRangeMode: Sendable, Equatable {
    case standardDynamicRange
    case extendedDynamicRange
    case automatic
}

public struct MetalPresentationEDRCapabilities: Sendable, Equatable {
    public var currentHeadroom: Double
    public var potentialHeadroom: Double

    public init(currentHeadroom: Double, potentialHeadroom: Double? = nil) {
        self.currentHeadroom = currentHeadroom
        self.potentialHeadroom = potentialHeadroom ?? currentHeadroom
    }

    public var supportsExtendedDynamicRange: Bool {
        max(currentHeadroom, potentialHeadroom) > 1.0
    }
}

public enum MetalPresentationUpscalingMode: String, Sendable, Equatable {
    case linear
    case metalFXSpatial
}

public enum MetalPresentationScalingStatus: Sendable, Equatable {
    case standard
    case metalFXSpatial
    case notNeeded
    case fallback
    case transition
}

/// Describes the last frame submitted to the GPU, not completed screen presentation.
public struct MetalPresentationDiagnostics: Sendable, Equatable {
    public let scalingStatus: MetalPresentationScalingStatus
    public let sourceSize: CGSize
    public let pictureSize: CGSize
    public let drawableSize: CGSize
    public let dynamicRangeMode: MetalPresentationDynamicRangeMode
}

public enum MetalPresentationBackground: Sendable, Equatable {
    case black
    case blurred
}

public struct MetalPresentationConfiguration: Sendable, Equatable {
    public var contentMode: MetalPresentationContentMode
    public var upscalingMode: MetalPresentationUpscalingMode
    public var background: MetalPresentationBackground
    public var dynamicRangeMode: MetalPresentationDynamicRangeMode
    public var edrCapabilities: MetalPresentationEDRCapabilities?
    public var preferredFrameRate: Int?

    public init(
        contentMode: MetalPresentationContentMode = .stretch,
        dynamicRangeMode: MetalPresentationDynamicRangeMode = .automatic,
        edrCapabilities: MetalPresentationEDRCapabilities? = nil,
        preferredFrameRate: Int? = nil,
        upscalingMode: MetalPresentationUpscalingMode = .linear,
        background: MetalPresentationBackground = .black
    ) {
        self.contentMode = contentMode
        self.upscalingMode = upscalingMode
        self.background = background
        self.dynamicRangeMode = dynamicRangeMode
        self.edrCapabilities = edrCapabilities
        self.preferredFrameRate = preferredFrameRate
    }
}

enum MetalResolvedPresentationDynamicRangeMode: Sendable, Equatable {
    case standardDynamicRange
    case extendedDynamicRange

    var drawablePixelFormat: MTLPixelFormat {
        switch self {
        case .standardDynamicRange:
            return .bgra8Unorm
        case .extendedDynamicRange:
            return .rgba16Float
        }
    }

    var colorOutputEncoding: MetalColorOutputEncoding {
        switch self {
        case .standardDynamicRange:
            return .sdrSRGB
        case .extendedDynamicRange:
            return .extendedLinearSRGB
        }
    }

    var layerColorSpace: CGColorSpace? {
        switch self {
        case .standardDynamicRange:
            return nil
        case .extendedDynamicRange:
            return CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        }
    }
}

extension MetalPresentationConfiguration {
    func resolvedDynamicRangeMode(for format: VideoFormat?) -> MetalResolvedPresentationDynamicRangeMode {
        switch dynamicRangeMode {
        case .standardDynamicRange:
            return .standardDynamicRange
        case .extendedDynamicRange:
            return .extendedDynamicRange
        case .automatic:
            guard format?.dynamicRange == .hdr,
                  edrCapabilities?.supportsExtendedDynamicRange != false else {
                return .standardDynamicRange
            }
            return .extendedDynamicRange
        }
    }
}
#endif
