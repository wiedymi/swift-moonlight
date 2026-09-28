import Foundation
import SwiftMoonlight
#if canImport(CoreImage) && canImport(CoreVideo) && canImport(ImageIO) && canImport(UniformTypeIdentifiers)
import CoreGraphics
import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
#if canImport(Metal)
import Metal
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

#if canImport(Metal)
actor MetalReadbackTarget: MetalFrameTarget {
    private let device: MTLDevice
    private let outputDirectory: URL
    private let frameLimit: Int
    private let commandQueue: MTLCommandQueue
    private let vertexBuffer: MTLBuffer
    private let rgbPipelineState: MTLRenderPipelineState
    private let biPlanarPipelineState: MTLRenderPipelineState
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var capturedFiles: [URL] = []
    private var preparedFormat: VideoFormat?

    init(device: MTLDevice, outputDirectory: URL, frameLimit: Int) throws {
        self.device = device
        self.outputDirectory = outputDirectory
        self.frameLimit = frameLimit

        guard let commandQueue = device.makeCommandQueue() else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to create Metal readback command queue")
        }
        self.commandQueue = commandQueue

        let vertices: [Float] = [
            -1, -1, 0, 1,
             3, -1, 2, 1,
            -1,  3, 0, -1
        ]
        guard let vertexBuffer = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<Float>.stride) else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to create Metal readback vertex buffer")
        }
        self.vertexBuffer = vertexBuffer

        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        self.rgbPipelineState = try device.makeRenderPipelineState(
            descriptor: Self.makePipelineDescriptor(library: library, fragmentFunction: "fragmentRGB")
        )
        self.biPlanarPipelineState = try device.makeRenderPipelineState(
            descriptor: Self.makePipelineDescriptor(library: library, fragmentFunction: "fragmentBiPlanar")
        )
    }

    func prepare(format: VideoFormat) async throws {
        preparedFormat = format
    }

    func present(_ frame: MetalPresentedFrame) async {
        guard capturedFiles.count < frameLimit else {
            return
        }

        let width = max(Int(frame.dimensions.width.rounded()), 1)
        let height = max(Int(frame.dimensions.height.rounded()), 1)

        do {
            let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            textureDescriptor.usage = [.renderTarget]
            textureDescriptor.storageMode = .shared
            guard let outputTexture = device.makeTexture(descriptor: textureDescriptor) else {
                throw MoonlightError(.unsupportedOperation, message: "Failed to create Metal readback texture")
            }
            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                throw MoonlightError(.unsupportedOperation, message: "Failed to create Metal readback command buffer")
            }

            let passDescriptor = MTLRenderPassDescriptor()
            passDescriptor.colorAttachments[0].texture = outputTexture
            passDescriptor.colorAttachments[0].loadAction = .clear
            passDescriptor.colorAttachments[0].storeAction = .store
            passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
                throw MoonlightError(.unsupportedOperation, message: "Failed to create Metal readback encoder")
            }

            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            switch frame.textures {
            case .rgb(let texture):
                encoder.setRenderPipelineState(rgbPipelineState)
                encoder.setFragmentTexture(texture, index: 0)
            case .biPlanar(let luma, let chroma):
                encoder.setRenderPipelineState(biPlanarPipelineState)
                encoder.setFragmentTexture(luma, index: 0)
                encoder.setFragmentTexture(chroma, index: 1)
                var conversion = frame.colorConversion.makeCaptureShaderUniform()
                encoder.setFragmentBytes(
                    &conversion,
                    length: MemoryLayout<CaptureColorConversionUniform>.stride,
                    index: 0
                )
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()

            await withCheckedContinuation { continuation in
                commandBuffer.addCompletedHandler { _ in
                    continuation.resume()
                }
                commandBuffer.commit()
            }

            let bytesPerRow = width * 4
            var data = Data(repeating: 0, count: bytesPerRow * height)
            data.withUnsafeMutableBytes { outputBytes in
                guard let baseAddress = outputBytes.baseAddress else {
                    return
                }
                outputTexture.getBytes(
                    baseAddress,
                    bytesPerRow: bytesPerRow,
                    from: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0
                )
            }

            let fileURL = outputDirectory.appending(path: fileName(for: frame, index: capturedFiles.count + 1))
            try Self.writeBGRAImage(
                data: data,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                colorSpace: colorSpace,
                destinationURL: fileURL
            )
            capturedFiles.append(fileURL)
        } catch {
            fputs("swift-moonlight-capture metal warning: \(error)\n", stderr)
        }
    }

    func teardown() async {}

    func snapshotFiles() -> [URL] {
        capturedFiles
    }

    private func fileName(for frame: MetalPresentedFrame, index: Int) -> String {
        let formatSuffix: String
        if let preparedFormat {
            switch preparedFormat.codec {
            case .hevc:
                formatSuffix = "hevc"
            case .h264:
                formatSuffix = "h264"
            case .av1:
                formatSuffix = "av1"
            }
        } else {
            formatSuffix = "unknown"
        }
        let width = Int(frame.dimensions.width.rounded())
        let height = Int(frame.dimensions.height.rounded())
        return String(format: "metal-frame-%04d-%@-%dx%d-ts-%llu.png", index, formatSuffix, width, height, frame.timestamp)
    }

    private static func makePipelineDescriptor(
        library: MTLLibrary,
        fragmentFunction: String
    ) -> MTLRenderPipelineDescriptor {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.vertexFunction = library.makeFunction(name: "vertexMain")
        descriptor.fragmentFunction = library.makeFunction(name: fragmentFunction)
        return descriptor
    }

    private static func writeBGRAImage(
        data: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        colorSpace: CGColorSpace,
        destinationURL: URL
    ) throws {
        let provider = CGDataProvider(data: data as CFData)
        guard let provider else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to create Metal readback provider")
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(.init(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to create Metal readback image")
        }
        guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to create Metal readback destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to finalize Metal readback image")
        }
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
    };

    struct ColorConversionUniform {
        float4 offsets;
        float4 scales;
        float4 matrixR;
        float4 matrixG;
        float4 matrixB;
        uint transferFunction;
        uint ycbcrMatrix;
        uint padding0;
        uint padding1;
    };

    vertex VertexOut vertexMain(uint vertexID [[vertex_id]], const device float4* vertices [[buffer(0)]]) {
        VertexOut out;
        float4 entry = vertices[vertexID];
        out.position = float4(entry.xy, 0.0, 1.0);
        out.texCoord = entry.zw;
        return out;
    }

    fragment float4 fragmentRGB(VertexOut in [[stage_in]], texture2d<float> colorTexture [[texture(0)]]) {
        constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
        return colorTexture.sample(textureSampler, in.texCoord);
    }

    float3 linearToSRGB(float3 linear) {
        linear = max(linear, float3(0.0));
        float3 low = linear * 12.92;
        float3 high = 1.055 * pow(linear, float3(1.0 / 2.4)) - 0.055;
        return select(high, low, linear <= float3(0.0031308));
    }

    float3 bt2020LinearToBT709Linear(float3 rgb) {
        // Match the app renderer: HDR decode is BT.2020, while PNG readback is SDR BT.709.
        return float3(
            dot(float3(1.6605, -0.5876, -0.0728), rgb),
            dot(float3(-0.1246, 1.1329, -0.0083), rgb),
            dot(float3(-0.0182, -0.1006, 1.1187), rgb)
        );
    }

    float3 toneMapHDRToSDR(float3 nits) {
        // Avoid diagnostic PNGs that look blown out just because highlights exceed SDR white.
        float3 reference = max(nits / 203.0, float3(0.0));
        float3 linearRegion = reference * 0.78;
        float3 shoulder = 0.78 + 0.22 * (1.0 - exp(-(reference - 1.0) * 0.35));
        return min(select(shoulder, linearRegion, reference <= float3(1.0)), float3(1.0));
    }

    float3 pqToSRGB(float3 pq, uint ycbcrMatrix) {
        constexpr float m1 = 2610.0 / 16384.0;
        constexpr float m2 = 2523.0 / 32.0;
        constexpr float c1 = 3424.0 / 4096.0;
        constexpr float c2 = 2413.0 / 128.0;
        constexpr float c3 = 2392.0 / 128.0;
        pq = clamp(pq, float3(0.0), float3(1.0));
        float3 p = pow(pq, float3(1.0 / m2));
        float3 numerator = max(p - c1, float3(0.0));
        float3 denominator = max(c2 - c3 * p, float3(0.000001));
        float3 nits = pow(numerator / denominator, float3(1.0 / m1)) * 10000.0;
        if (ycbcrMatrix == 1) {
            nits = bt2020LinearToBT709Linear(nits);
        }
        return linearToSRGB(toneMapHDRToSDR(nits));
    }

    float3 hlgToSRGB(float3 hlg, uint ycbcrMatrix) {
        constexpr float a = 0.17883277;
        constexpr float b = 0.28466892;
        constexpr float c = 0.55991073;
        hlg = clamp(hlg, float3(0.0), float3(1.0));
        float3 low = (hlg * hlg) / 3.0;
        float3 high = (exp((hlg - c) / a) + b) / 12.0;
        float3 sceneLinear = select(high, low, hlg <= float3(0.5));
        float3 nits = sceneLinear * 1000.0;
        if (ycbcrMatrix == 1) {
            nits = bt2020LinearToBT709Linear(nits);
        }
        return linearToSRGB(toneMapHDRToSDR(nits));
    }

    fragment float4 fragmentBiPlanar(
        VertexOut in [[stage_in]],
        texture2d<float> lumaTexture [[texture(0)]],
        texture2d<float> chromaTexture [[texture(1)]],
        constant ColorConversionUniform& conversion [[buffer(0)]]
    ) {
        constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
        float y = (lumaTexture.sample(textureSampler, in.texCoord).r - conversion.offsets.x) * conversion.scales.x;
        float2 cbcr = (chromaTexture.sample(textureSampler, in.texCoord).rg - conversion.offsets.yz) * conversion.scales.yz;
        float3 ycbcr = float3(y, cbcr.x, cbcr.y);

        float3 rgb = float3(
            dot(conversion.matrixR.xyz, ycbcr),
            dot(conversion.matrixG.xyz, ycbcr),
            dot(conversion.matrixB.xyz, ycbcr)
        );

        if (conversion.transferFunction == 1) {
            rgb = pqToSRGB(rgb, conversion.ycbcrMatrix);
        } else if (conversion.transferFunction == 2) {
            rgb = hlgToSRGB(rgb, conversion.ycbcrMatrix);
        }

        return float4(saturate(rgb), 1.0);
    }
    """
}

struct CaptureColorConversionUniform {
    var offsets: SIMD4<Float>
    var scales: SIMD4<Float>
    var matrixR: SIMD4<Float>
    var matrixG: SIMD4<Float>
    var matrixB: SIMD4<Float>
    var transferFunction: UInt32
    var ycbcrMatrix: UInt32
    var padding0: UInt32 = 0
    var padding1: UInt32 = 0
}

private extension MetalColorConversion {
    func makeCaptureShaderUniform() -> CaptureColorConversionUniform {
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

        return CaptureColorConversionUniform(
            offsets: SIMD4<Float>(yOffset, chromaOffset, chromaOffset, 0),
            scales: SIMD4<Float>(yScale, chromaScale, chromaScale, 1),
            matrixR: rows.0,
            matrixG: rows.1,
            matrixB: rows.2,
            transferFunction: transferFunction.rawValue,
            ycbcrMatrix: ycbcrMatrix.rawValue
        )
    }
}
#endif
#endif
