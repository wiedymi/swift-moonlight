#if canImport(Metal) && canImport(QuartzCore)
import CoreGraphics
import Foundation
import Metal
import QuartzCore

/// Safety invariant:
/// - Ownership of the layer is transferred to `MetalLayerTarget` for rendering.
/// - The caller must not concurrently mutate the layer after passing it in.
struct SendableMetalLayerReference: @unchecked Sendable {
    let layer: CAMetalLayer
}

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

public struct MetalPresentationConfiguration: Sendable, Equatable {
    public var contentMode: MetalPresentationContentMode
    public var dynamicRangeMode: MetalPresentationDynamicRangeMode
    public var edrCapabilities: MetalPresentationEDRCapabilities?

    public init(
        contentMode: MetalPresentationContentMode = .stretch,
        dynamicRangeMode: MetalPresentationDynamicRangeMode = .automatic,
        edrCapabilities: MetalPresentationEDRCapabilities? = nil
    ) {
        self.contentMode = contentMode
        self.dynamicRangeMode = dynamicRangeMode
        self.edrCapabilities = edrCapabilities
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

public struct MetalPresentationGeometry: Sendable, Equatable {
    public var frameDimensions: CGSize
    public var drawableSize: CGSize
    public var contentRect: CGRect
    public var sourceRect: CGRect

    public init(
        contentMode: MetalPresentationContentMode,
        frameDimensions: CGSize,
        drawableSize: CGSize
    ) {
        let geometry = Self.make(
            contentMode: contentMode,
            frameDimensions: frameDimensions,
            drawableSize: drawableSize
        )
        self.frameDimensions = geometry.frameDimensions
        self.drawableSize = geometry.drawableSize
        self.contentRect = geometry.contentRect
        self.sourceRect = geometry.sourceRect
    }

    public func normalizedFramePoint(
        forDrawablePoint point: CGPoint,
        clamping: Bool = true
    ) -> CGPoint? {
        guard contentRect.width > 0, contentRect.height > 0, sourceRect.width > 0, sourceRect.height > 0 else {
            return nil
        }
        guard clamping || contentRect.includes(point) else {
            return nil
        }

        let confinedPoint = CGPoint(
            x: point.x.clamped(to: contentRect.minX...contentRect.maxX),
            y: point.y.clamped(to: contentRect.minY...contentRect.maxY)
        )
        let localX = (confinedPoint.x - contentRect.minX) / contentRect.width
        let localY = (confinedPoint.y - contentRect.minY) / contentRect.height
        return CGPoint(
            x: (sourceRect.minX + localX * sourceRect.width).clamped(to: 0...1),
            y: (sourceRect.minY + localY * sourceRect.height).clamped(to: 0...1)
        )
    }

    private init(
        frameDimensions: CGSize,
        drawableSize: CGSize,
        contentRect: CGRect,
        sourceRect: CGRect
    ) {
        self.frameDimensions = frameDimensions
        self.drawableSize = drawableSize
        self.contentRect = contentRect
        self.sourceRect = sourceRect
    }

    private static func make(
        contentMode: MetalPresentationContentMode,
        frameDimensions: CGSize,
        drawableSize: CGSize
    ) -> MetalPresentationGeometry {
        let drawableRect = CGRect(origin: .zero, size: drawableSize.sanitizedForPresentation)
        let fullSourceRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard contentMode != .stretch,
              frameDimensions.width > 0,
              frameDimensions.height > 0,
              drawableRect.width > 0,
              drawableRect.height > 0 else {
            return MetalPresentationGeometry(
                frameDimensions: frameDimensions,
                drawableSize: drawableSize,
                contentRect: drawableRect,
                sourceRect: fullSourceRect
            )
        }

        let frameAspect = Double(frameDimensions.width / frameDimensions.height)
        let drawableAspect = Double(drawableRect.width / drawableRect.height)
        guard frameAspect.isFinite, drawableAspect.isFinite, frameAspect > 0, drawableAspect > 0 else {
            return MetalPresentationGeometry(
                frameDimensions: frameDimensions,
                drawableSize: drawableSize,
                contentRect: drawableRect,
                sourceRect: fullSourceRect
            )
        }

        switch contentMode {
        case .stretch:
            return MetalPresentationGeometry(
                frameDimensions: frameDimensions,
                drawableSize: drawableSize,
                contentRect: drawableRect,
                sourceRect: fullSourceRect
            )
        case .aspectFit:
            let contentRect: CGRect
            if frameAspect > drawableAspect {
                let height = drawableRect.width / CGFloat(frameAspect)
                contentRect = CGRect(
                    x: 0,
                    y: (drawableRect.height - height) / 2,
                    width: drawableRect.width,
                    height: height
                )
            } else {
                let width = drawableRect.height * CGFloat(frameAspect)
                contentRect = CGRect(
                    x: (drawableRect.width - width) / 2,
                    y: 0,
                    width: width,
                    height: drawableRect.height
                )
            }
            return MetalPresentationGeometry(
                frameDimensions: frameDimensions,
                drawableSize: drawableSize,
                contentRect: contentRect,
                sourceRect: fullSourceRect
            )
        case .aspectFill:
            let sourceRect: CGRect
            if frameAspect > drawableAspect {
                let width = CGFloat(drawableAspect / frameAspect)
                sourceRect = CGRect(x: (1 - width) / 2, y: 0, width: width, height: 1)
            } else {
                let height = CGFloat(frameAspect / drawableAspect)
                sourceRect = CGRect(x: 0, y: (1 - height) / 2, width: 1, height: height)
            }
            return MetalPresentationGeometry(
                frameDimensions: frameDimensions,
                drawableSize: drawableSize,
                contentRect: drawableRect,
                sourceRect: sourceRect
            )
        }
    }
}

struct MetalPresentationTransform: Sendable, Equatable {
    var scale: SIMD2<Float>

    static let stretch = MetalPresentationTransform(scale: SIMD2<Float>(1, 1))

    static func make(
        contentMode: MetalPresentationContentMode,
        frameDimensions: CGSize,
        drawableSize: CGSize
    ) -> MetalPresentationTransform {
        guard contentMode != .stretch,
              frameDimensions.width > 0,
              frameDimensions.height > 0,
              drawableSize.width > 0,
              drawableSize.height > 0 else {
            return .stretch
        }

        let frameAspect = Double(frameDimensions.width / frameDimensions.height)
        let drawableAspect = Double(drawableSize.width / drawableSize.height)
        guard frameAspect.isFinite, drawableAspect.isFinite, frameAspect > 0, drawableAspect > 0 else {
            return .stretch
        }

        switch contentMode {
        case .stretch:
            return .stretch
        case .aspectFit:
            if frameAspect > drawableAspect {
                return MetalPresentationTransform(scale: SIMD2<Float>(1, Float(drawableAspect / frameAspect)))
            }
            return MetalPresentationTransform(scale: SIMD2<Float>(Float(frameAspect / drawableAspect), 1))
        case .aspectFill:
            if frameAspect > drawableAspect {
                return MetalPresentationTransform(scale: SIMD2<Float>(Float(frameAspect / drawableAspect), 1))
            }
            return MetalPresentationTransform(scale: SIMD2<Float>(1, Float(drawableAspect / frameAspect)))
        }
    }
}

struct MetalPresentationUniform {
    var scale: SIMD2<Float>
}

private extension CGSize {
    var sanitizedForPresentation: CGSize {
        CGSize(width: Swift.max(width, 0), height: Swift.max(height, 0))
    }
}

private extension CGRect {
    func includes(_ point: CGPoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

#endif
