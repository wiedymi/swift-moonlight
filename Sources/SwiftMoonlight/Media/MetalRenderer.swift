#if canImport(Metal) && canImport(CoreVideo)
import CoreGraphics
import CoreVideo
import Foundation
import Metal

public enum MetalTexturePlanes: @unchecked Sendable {
    case rgb(MTLTexture)
    case biPlanar(luma: MTLTexture, chroma: MTLTexture)
}

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

public protocol MetalFrameTarget: Sendable {
    func prepare(format: VideoFormat) async throws
    func present(_ frame: MetalPresentedFrame) async
    func teardown() async
}

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
