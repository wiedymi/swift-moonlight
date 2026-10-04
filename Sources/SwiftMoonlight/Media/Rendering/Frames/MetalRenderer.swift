#if canImport(Metal) && canImport(CoreVideo)
import CoreGraphics
import CoreVideo
import Foundation
import Metal

public actor MetalRenderer: FrameRenderer {
    private let device: MTLDevice
    private let target: any MetalFrameTarget
    private let diagnosticsHandler: (@Sendable (MetalFrameDiagnostics) async -> Void)?
    private var format: VideoFormat?
    private var textureCache: CVMetalTextureCache?
    private var lastDiagnostics: MetalFrameDiagnostics?

    public init(
        device: MTLDevice,
        target: any MetalFrameTarget,
        diagnosticsHandler: (@Sendable (MetalFrameDiagnostics) async -> Void)? = nil
    ) throws {
        self.device = device
        self.target = target
        self.diagnosticsHandler = diagnosticsHandler

        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to create CVMetalTextureCache: \(status)")
        }

        textureCache = cache
    }

    public func prepare(format: VideoFormat) async throws {
        self.format = format
        try await target.prepare(format: format)
    }

    public func render(_ frame: DecodedVideoFrame) async {
        guard format != nil else {
            return
        }

        #if canImport(CoreVideo)
        guard let pixelBuffer = frame.pixelBuffer else {
            return
        }

        do {
            await emitDiagnosticsIfNeeded(for: pixelBuffer.pixelBuffer)
            let presentedFrame = try makePresentedFrame(
                from: pixelBuffer,
                timestamp: frame.timestamp,
                dimensions: frame.dimensions
            )
            await target.present(presentedFrame)
        } catch {
            return
        }
        #endif
    }

    public func teardown() async {
        format = nil
        if let textureCache {
            CVMetalTextureCacheFlush(textureCache, 0)
        }
        await target.teardown()
    }

    private func makePresentedFrame(
        from pixelBufferBox: PixelBufferBox,
        timestamp: UInt64,
        dimensions: CGSize
    ) throws -> MetalPresentedFrame {
        guard let textureCache else {
            throw MoonlightError(.unsupportedOperation, message: "Metal renderer is missing its texture cache")
        }

        let pixelBuffer = pixelBufferBox.pixelBuffer
        let sourcePixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let colorConversion = colorConversion(for: pixelBuffer)
        var retainedObjects: [AnyObject] = [pixelBufferBox]
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        if planeCount == 0 {
            let (texture, retainedObject) = try makeTexture(
                cache: textureCache,
                pixelBuffer: pixelBuffer,
                pixelFormat: metalPixelFormat(for: sourcePixelFormat, planeIndex: nil),
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer),
                planeIndex: 0
            )
            retainedObjects.append(retainedObject)
            return MetalPresentedFrame(
                timestamp: timestamp,
                dimensions: dimensions,
                textures: .rgb(texture),
                colorConversion: colorConversion,
                retainedResources: MetalFrameResources(retainedObjects: retainedObjects)
            )
        }

        if planeCount == 2 {
            let (lumaTexture, lumaRetainedObject) = try makeTexture(
                cache: textureCache,
                pixelBuffer: pixelBuffer,
                pixelFormat: metalPixelFormat(for: sourcePixelFormat, planeIndex: 0),
                width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
                height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
                planeIndex: 0
            )
            retainedObjects.append(lumaRetainedObject)
            let (chromaTexture, chromaRetainedObject) = try makeTexture(
                cache: textureCache,
                pixelBuffer: pixelBuffer,
                pixelFormat: metalPixelFormat(for: sourcePixelFormat, planeIndex: 1),
                width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
                height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 1),
                planeIndex: 1
            )
            retainedObjects.append(chromaRetainedObject)
            return MetalPresentedFrame(
                timestamp: timestamp,
                dimensions: dimensions,
                textures: .biPlanar(luma: lumaTexture, chroma: chromaTexture),
                colorConversion: colorConversion,
                retainedResources: MetalFrameResources(retainedObjects: retainedObjects)
            )
        }

        throw MoonlightError(.unsupportedOperation, message: "Unsupported pixel buffer plane count: \(planeCount)")
    }

    private func makeTexture(
        cache: CVMetalTextureCache,
        pixelBuffer: CVPixelBuffer,
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int,
        planeIndex: Int
    ) throws -> (texture: MTLTexture, retainedObject: AnyObject) {
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            planeIndex,
            &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to create Metal texture: \(status)")
        }

        return (texture, cvTexture as AnyObject)
    }

    private func metalPixelFormat(for pixelFormat: OSType, planeIndex: Int?) -> MTLPixelFormat {
        switch pixelFormat {
        case kCVPixelFormatType_32BGRA:
            return .bgra8Unorm
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarFullRange:
            return planeIndex == 0 ? .r8Unorm : .rg8Unorm
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange,
             kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarFullRange,
             kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarVideoRange:
            return planeIndex == 0 ? .r16Unorm : .rg16Unorm
        default:
            return .bgra8Unorm
        }
    }

    private func colorConversion(for pixelBuffer: CVPixelBuffer) -> MetalColorConversion {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let transferFunction = transferFunction(from: pixelBuffer) ?? .sdr
        return MetalColorConversion(
            transferFunction: transferFunction,
            ycbcrRange: isVideoRangePixelFormat(pixelFormat) ? .video : .full,
            ycbcrMatrix: ycbcrMatrix(from: pixelBuffer) ?? defaultYCbCrMatrix(for: transferFunction),
            componentBitDepth: isTenBitPixelFormat(pixelFormat) ? 10 : 8
        )
    }

    private func emitDiagnosticsIfNeeded(for pixelBuffer: CVPixelBuffer) async {
        guard let diagnosticsHandler else {
            return
        }

        let diagnostics = makeDiagnostics(for: pixelBuffer)
        guard diagnostics != lastDiagnostics else {
            return
        }

        lastDiagnostics = diagnostics
        await diagnosticsHandler(diagnostics)
    }

    private func makeDiagnostics(for pixelBuffer: CVPixelBuffer) -> MetalFrameDiagnostics {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        return MetalFrameDiagnostics(
            dimensions: CGSize(
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer)
            ),
            pixelFormat: UInt32(pixelFormat),
            pixelFormatName: Self.fourCharacterCode(pixelFormat),
            planeCount: CVPixelBufferGetPlaneCount(pixelBuffer),
            colorConversion: colorConversion(for: pixelBuffer),
            attachments: colorAttachments(from: pixelBuffer)
        )
    }

    private func transferFunction(from pixelBuffer: CVPixelBuffer) -> MetalColorConversion.TransferFunction? {
        guard let value = attachmentValue(kCVImageBufferTransferFunctionKey, from: pixelBuffer) else {
            return nil
        }

        if CFEqual(value, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) {
            return .pq
        }
        if CFEqual(value, kCVImageBufferTransferFunction_ITU_R_2100_HLG) {
            return .hlg
        }
        return .sdr
    }

    private func ycbcrMatrix(from pixelBuffer: CVPixelBuffer) -> MetalColorConversion.YCbCrMatrix? {
        guard let value = attachmentValue(kCVImageBufferYCbCrMatrixKey, from: pixelBuffer) else {
            return nil
        }

        if CFEqual(value, kCVImageBufferYCbCrMatrix_ITU_R_2020) {
            return .bt2020
        }
        if CFEqual(value, kCVImageBufferYCbCrMatrix_ITU_R_709_2) {
            return .bt709
        }
        if CFEqual(value, kCVImageBufferYCbCrMatrix_ITU_R_601_4) {
            return .bt601
        }
        return nil
    }

    private func defaultYCbCrMatrix(
        for transferFunction: MetalColorConversion.TransferFunction
    ) -> MetalColorConversion.YCbCrMatrix {
        switch transferFunction {
        case .pq, .hlg:
            return .bt2020
        case .sdr:
            return .bt709
        }
    }

    private func colorAttachments(from pixelBuffer: CVPixelBuffer) -> [String: String] {
        [
            "colorPrimaries": attachmentDescription(kCVImageBufferColorPrimariesKey, from: pixelBuffer),
            "transfer": attachmentDescription(kCVImageBufferTransferFunctionKey, from: pixelBuffer),
            "ycbcrMatrix": attachmentDescription(kCVImageBufferYCbCrMatrixKey, from: pixelBuffer),
            "chromaTop": attachmentDescription(kCVImageBufferChromaLocationTopFieldKey, from: pixelBuffer),
            "chromaBottom": attachmentDescription(kCVImageBufferChromaLocationBottomFieldKey, from: pixelBuffer),
        ].compactMapValues { $0 }
    }

    private func attachmentDescription(_ key: CFString, from pixelBuffer: CVPixelBuffer) -> String? {
        attachmentValue(key, from: pixelBuffer).map { String(describing: $0) }
    }

    private func attachmentValue(_ key: CFString, from pixelBuffer: CVPixelBuffer) -> CFTypeRef? {
        CVBufferCopyAttachment(pixelBuffer, key, nil)
    }

    private static func fourCharacterCode(_ pixelFormat: OSType) -> String {
        let bytes: [UInt8] = [
            UInt8((pixelFormat >> 24) & 0xff),
            UInt8((pixelFormat >> 16) & 0xff),
            UInt8((pixelFormat >> 8) & 0xff),
            UInt8(pixelFormat & 0xff),
        ]

        guard bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }) else {
            return String(pixelFormat)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func isVideoRangePixelFormat(_ pixelFormat: OSType) -> Bool {
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange,
             kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarVideoRange:
            return true
        default:
            return false
        }
    }

    private func isTenBitPixelFormat(_ pixelFormat: OSType) -> Bool {
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange,
             kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarFullRange,
             kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarVideoRange:
            return true
        default:
            return false
        }
    }
}
#endif
