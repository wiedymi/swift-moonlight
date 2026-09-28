#if canImport(Metal) && canImport(QuartzCore)
import CoreGraphics
import Metal
import QuartzCore
import Testing
@testable import SwiftMoonlight

@Test
func metalPresentationTransformStretchesByDefault() {
    let transform = MetalPresentationTransform.make(
        contentMode: .stretch,
        frameDimensions: CGSize(width: 1920, height: 1080),
        drawableSize: CGSize(width: 1024, height: 768)
    )

    expectScale(transform, x: 1, y: 1)
}

@Test
func metalLayerTargetPreparesStandardDynamicRangeLayerByDefault() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
        return
    }

    let layerReference = SendableMetalLayerReference(layer: CAMetalLayer())
    let target = try MetalLayerTarget(device: device, layerReference: layerReference)

    try await target.prepare(format: VideoFormat(codec: .hevc, dimensions: CGSize(width: 1_920, height: 1_080)))

    #expect(layerReference.layer.pixelFormat == .bgra8Unorm)
    #expect(layerReference.layer.colorspace == nil)
    #if os(macOS) || os(iOS)
    #expect(layerReference.layer.wantsExtendedDynamicRangeContent == false)
    #endif
}

@Test
func metalLayerTargetPreparesExtendedDynamicRangeLayerByDefaultForHDR() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
        return
    }

    let layerReference = SendableMetalLayerReference(layer: CAMetalLayer())
    let target = try MetalLayerTarget(device: device, layerReference: layerReference)

    try await target.prepare(
        format: VideoFormat(
            codec: .hevc,
            dimensions: CGSize(width: 1_920, height: 1_080),
            dynamicRange: .hdr
        )
    )

    #expect(layerReference.layer.pixelFormat == .rgba16Float)
    #expect(layerReference.layer.colorspace != nil)
    #if os(macOS) || os(iOS)
    #expect(layerReference.layer.wantsExtendedDynamicRangeContent == true)
    #endif
}

@Test
func metalLayerTargetPreparesExtendedDynamicRangeLayerWhenRequested() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
        return
    }

    let layerReference = SendableMetalLayerReference(layer: CAMetalLayer())
    let target = try MetalLayerTarget(
        device: device,
        layerReference: layerReference,
        presentationConfiguration: MetalPresentationConfiguration(dynamicRangeMode: .extendedDynamicRange)
    )

    try await target.prepare(
        format: VideoFormat(
            codec: .hevc,
            dimensions: CGSize(width: 1_920, height: 1_080),
            dynamicRange: .hdr
        )
    )

    #expect(layerReference.layer.pixelFormat == .rgba16Float)
    #expect(layerReference.layer.colorspace != nil)
    #if os(macOS) || os(iOS)
    #expect(layerReference.layer.wantsExtendedDynamicRangeContent == true)
    #endif
}

@Test
func metalLayerTargetKeepsSDRWhenExplicitlyRequestedForHDR() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
        return
    }

    let layerReference = SendableMetalLayerReference(layer: CAMetalLayer())
    let target = try MetalLayerTarget(
        device: device,
        layerReference: layerReference,
        presentationConfiguration: MetalPresentationConfiguration(dynamicRangeMode: .standardDynamicRange)
    )

    try await target.prepare(
        format: VideoFormat(
            codec: .hevc,
            dimensions: CGSize(width: 1_920, height: 1_080),
            dynamicRange: .hdr
        )
    )

    #expect(layerReference.layer.pixelFormat == .bgra8Unorm)
    #expect(layerReference.layer.colorspace == nil)
    #if os(macOS) || os(iOS)
    #expect(layerReference.layer.wantsExtendedDynamicRangeContent == false)
    #endif
}

@Test
func metalLayerTargetAutomaticDynamicRangeStaysSDRWhenCapabilitiesDenyEDR() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
        return
    }

    let layerReference = SendableMetalLayerReference(layer: CAMetalLayer())
    let target = try MetalLayerTarget(
        device: device,
        layerReference: layerReference,
        presentationConfiguration: MetalPresentationConfiguration(
            dynamicRangeMode: .automatic,
            edrCapabilities: MetalPresentationEDRCapabilities(currentHeadroom: 1.0)
        )
    )

    try await target.prepare(
        format: VideoFormat(
            codec: .hevc,
            dimensions: CGSize(width: 1_920, height: 1_080),
            dynamicRange: .hdr
        )
    )

    #expect(layerReference.layer.pixelFormat == .bgra8Unorm)
    #expect(layerReference.layer.colorspace == nil)
    #if os(macOS) || os(iOS)
    #expect(layerReference.layer.wantsExtendedDynamicRangeContent == false)
    #endif
}

@Test
func metalLayerTargetAutomaticDynamicRangeUsesEDRForHDRWhenCapabilitiesAllow() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
        return
    }

    let layerReference = SendableMetalLayerReference(layer: CAMetalLayer())
    let target = try MetalLayerTarget(
        device: device,
        layerReference: layerReference,
        presentationConfiguration: MetalPresentationConfiguration(
            dynamicRangeMode: .automatic,
            edrCapabilities: MetalPresentationEDRCapabilities(currentHeadroom: 1.0, potentialHeadroom: 1.5)
        )
    )

    try await target.prepare(
        format: VideoFormat(
            codec: .hevc,
            dimensions: CGSize(width: 1_920, height: 1_080),
            dynamicRange: .hdr
        )
    )

    #expect(layerReference.layer.pixelFormat == .rgba16Float)
    #expect(layerReference.layer.colorspace != nil)
    #if os(macOS) || os(iOS)
    #expect(layerReference.layer.wantsExtendedDynamicRangeContent == true)
    #endif
}

@Test
func metalPresentationTransformAspectFitsWiderFrame() {
    let transform = MetalPresentationTransform.make(
        contentMode: .aspectFit,
        frameDimensions: CGSize(width: 1920, height: 1080),
        drawableSize: CGSize(width: 1024, height: 768)
    )

    expectScale(transform, x: 1, y: 0.75)
}

@Test
func metalPresentationTransformAspectFitsTallerFrame() {
    let transform = MetalPresentationTransform.make(
        contentMode: .aspectFit,
        frameDimensions: CGSize(width: 1024, height: 768),
        drawableSize: CGSize(width: 1920, height: 1080)
    )

    expectScale(transform, x: 0.75, y: 1)
}

@Test
func metalPresentationTransformAspectFillsWiderFrame() {
    let transform = MetalPresentationTransform.make(
        contentMode: .aspectFill,
        frameDimensions: CGSize(width: 1920, height: 1080),
        drawableSize: CGSize(width: 1024, height: 768)
    )

    expectScale(transform, x: 4.0 / 3.0, y: 1)
}

@Test
func metalPresentationTransformAspectFillsTallerFrame() {
    let transform = MetalPresentationTransform.make(
        contentMode: .aspectFill,
        frameDimensions: CGSize(width: 1024, height: 768),
        drawableSize: CGSize(width: 1920, height: 1080)
    )

    expectScale(transform, x: 1, y: 4.0 / 3.0)
}

@Test
func metalPresentationTransformFallsBackToStretchForInvalidSizes() {
    let transform = MetalPresentationTransform.make(
        contentMode: .aspectFit,
        frameDimensions: CGSize(width: 0, height: 1080),
        drawableSize: CGSize(width: 1024, height: 768)
    )

    expectScale(transform, x: 1, y: 1)
}

@Test
func metalPresentationGeometryReportsAspectFitContentRect() {
    let geometry = MetalPresentationGeometry(
        contentMode: .aspectFit,
        frameDimensions: CGSize(width: 1920, height: 1080),
        drawableSize: CGSize(width: 1024, height: 768)
    )

    expectRect(geometry.contentRect, x: 0, y: 96, width: 1024, height: 576)
    expectRect(geometry.sourceRect, x: 0, y: 0, width: 1, height: 1)
}

@Test
func metalPresentationGeometryReportsAspectFillSourceCrop() {
    let geometry = MetalPresentationGeometry(
        contentMode: .aspectFill,
        frameDimensions: CGSize(width: 1920, height: 1080),
        drawableSize: CGSize(width: 1024, height: 768)
    )

    expectRect(geometry.contentRect, x: 0, y: 0, width: 1024, height: 768)
    expectRect(geometry.sourceRect, x: 0.125, y: 0, width: 0.75, height: 1)
}

@Test
func metalPresentationGeometryMapsDrawablePointIntoAspectFitSourcePoint() throws {
    let geometry = MetalPresentationGeometry(
        contentMode: .aspectFit,
        frameDimensions: CGSize(width: 1920, height: 1080),
        drawableSize: CGSize(width: 1024, height: 768)
    )

    let point = try #require(geometry.normalizedFramePoint(forDrawablePoint: CGPoint(x: 512, y: 384)))
    expectPoint(point, x: 0.5, y: 0.5)

    #expect(geometry.normalizedFramePoint(forDrawablePoint: CGPoint(x: 512, y: 32), clamping: false) == nil)
    let clampedPoint = try #require(geometry.normalizedFramePoint(forDrawablePoint: CGPoint(x: 512, y: 32)))
    expectPoint(clampedPoint, x: 0.5, y: 0)
}

@Test
func metalPresentationGeometryMapsDrawablePointIntoAspectFillCroppedSourcePoint() throws {
    let geometry = MetalPresentationGeometry(
        contentMode: .aspectFill,
        frameDimensions: CGSize(width: 1920, height: 1080),
        drawableSize: CGSize(width: 1024, height: 768)
    )

    let leftEdge = try #require(geometry.normalizedFramePoint(forDrawablePoint: CGPoint(x: 0, y: 384)))
    expectPoint(leftEdge, x: 0.125, y: 0.5)

    let rightEdge = try #require(geometry.normalizedFramePoint(forDrawablePoint: CGPoint(x: 1024, y: 384)))
    expectPoint(rightEdge, x: 0.875, y: 0.5)
}

private func expectScale(_ transform: MetalPresentationTransform, x: Float, y: Float) {
    #expect(abs(transform.scale.x - x) < 0.0001)
    #expect(abs(transform.scale.y - y) < 0.0001)
}

private func expectRect(
    _ rect: CGRect,
    x: CGFloat,
    y: CGFloat,
    width: CGFloat,
    height: CGFloat
) {
    #expect(abs(rect.origin.x - x) < 0.0001)
    #expect(abs(rect.origin.y - y) < 0.0001)
    #expect(abs(rect.width - width) < 0.0001)
    #expect(abs(rect.height - height) < 0.0001)
}

private func expectPoint(_ point: CGPoint, x: CGFloat, y: CGFloat) {
    #expect(abs(point.x - x) < 0.0001)
    #expect(abs(point.y - y) < 0.0001)
}
#endif
