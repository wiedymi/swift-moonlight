#if canImport(Metal) && canImport(QuartzCore)
import CoreGraphics
import Foundation
import Metal
import QuartzCore

public actor MetalLayerTarget: MetalFrameTarget {
    private let device: MTLDevice
    private let layer: CAMetalLayer
    private let presentationConfiguration: MetalPresentationConfiguration
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary
    private let vertexBuffer: MTLBuffer
    private var activeDynamicRangeMode: MetalResolvedPresentationDynamicRangeMode
    private var rgbPipelineState: MTLRenderPipelineState
    private var biPlanarPipelineState: MTLRenderPipelineState

    public init(
        device: MTLDevice,
        layer: CAMetalLayer,
        presentationConfiguration: MetalPresentationConfiguration = MetalPresentationConfiguration()
    ) throws {
        try self.init(
            device: device,
            layerReference: SendableMetalLayerReference(layer: layer),
            presentationConfiguration: presentationConfiguration
        )
    }

    internal init(
        device: MTLDevice,
        layerReference: SendableMetalLayerReference,
        presentationConfiguration: MetalPresentationConfiguration = MetalPresentationConfiguration()
    ) throws {
        self.device = device
        self.layer = layerReference.layer
        self.presentationConfiguration = presentationConfiguration
        self.activeDynamicRangeMode = presentationConfiguration.resolvedDynamicRangeMode(for: nil)

        guard let commandQueue = device.makeCommandQueue() else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to create Metal command queue")
        }
        self.commandQueue = commandQueue

        let vertices: [Float] = [
            -1, -1, 0, 1,
             3, -1, 2, 1,
            -1,  3, 0, -1
        ]
        guard let vertexBuffer = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<Float>.stride) else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to create Metal vertex buffer")
        }
        self.vertexBuffer = vertexBuffer

        let library = try device.makeDefaultSwiftMoonlightLibrary()
        self.library = library
        self.rgbPipelineState = try device.makeRenderPipelineState(
            descriptor: Self.makePipelineDescriptor(
                library: library,
                fragmentFunction: "fragmentRGB",
                pixelFormat: activeDynamicRangeMode.drawablePixelFormat
            )
        )
        self.biPlanarPipelineState = try device.makeRenderPipelineState(
            descriptor: Self.makePipelineDescriptor(
                library: library,
                fragmentFunction: "fragmentBiPlanar",
                pixelFormat: activeDynamicRangeMode.drawablePixelFormat
            )
        )
    }

    public func prepare(format: VideoFormat) async throws {
        try activateDynamicRangeMode(presentationConfiguration.resolvedDynamicRangeMode(for: format))

        layer.device = device
        layer.pixelFormat = activeDynamicRangeMode.drawablePixelFormat
        layer.colorspace = activeDynamicRangeMode.layerColorSpace
        layer.framebufferOnly = false
        layer.isOpaque = true
        configureLayerDynamicRange()

        if layer.drawableSize.width <= 1 || layer.drawableSize.height <= 1 {
            let width = max(Int(format.dimensions.width.rounded(.up)), 1)
            let height = max(Int(format.dimensions.height.rounded(.up)), 1)
            layer.drawableSize = CGSize(width: width, height: height)
        }
    }

    public func present(_ frame: MetalPresentedFrame) async {
        autoreleasepool {
            guard let drawable = layer.nextDrawable(),
                  let commandBuffer = commandQueue.makeCommandBuffer() else {
                return
            }

            // Keep the CoreVideo-backed textures alive until the GPU finishes
            // sampling from them. Releasing the wrapper objects immediately
            // after commit can produce visible corruption on screen.
            commandBuffer.addCompletedHandler { [frame] _ in
                _ = frame
            }

            let passDescriptor = MTLRenderPassDescriptor()
            passDescriptor.colorAttachments[0].texture = drawable.texture
            passDescriptor.colorAttachments[0].loadAction = .clear
            passDescriptor.colorAttachments[0].storeAction = .store
            passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
                return
            }

            let transform = MetalPresentationTransform.make(
                contentMode: presentationConfiguration.contentMode,
                frameDimensions: frame.dimensions,
                drawableSize: CGSize(width: drawable.texture.width, height: drawable.texture.height)
            )
            var presentation = MetalPresentationUniform(scale: transform.scale)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(
                &presentation,
                length: MemoryLayout<MetalPresentationUniform>.stride,
                index: 1
            )
            switch frame.textures {
            case .rgb(let texture):
                encoder.setRenderPipelineState(rgbPipelineState)
                encoder.setFragmentTexture(texture, index: 0)
            case .biPlanar(let luma, let chroma):
                encoder.setRenderPipelineState(biPlanarPipelineState)
                encoder.setFragmentTexture(luma, index: 0)
                encoder.setFragmentTexture(chroma, index: 1)
                var conversion = frame.colorConversion.makeShaderUniform(
                    outputEncoding: activeDynamicRangeMode.colorOutputEncoding
                )
                encoder.setFragmentBytes(
                    &conversion,
                    length: MemoryLayout<MetalColorConversionUniform>.stride,
                    index: 0
                )
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }

    public func teardown() async {}

    private func configureLayerDynamicRange() {
        let wantsEDR = activeDynamicRangeMode == .extendedDynamicRange
        #if os(macOS) || os(iOS)
        layer.wantsExtendedDynamicRangeContent = wantsEDR
        if #available(macOS 26.0, iOS 26.0, *) {
            layer.preferredDynamicRange = wantsEDR ? .high : .standard
        }
        #endif
    }

    private func activateDynamicRangeMode(_ mode: MetalResolvedPresentationDynamicRangeMode) throws {
        guard mode != activeDynamicRangeMode else {
            return
        }

        rgbPipelineState = try device.makeRenderPipelineState(
            descriptor: Self.makePipelineDescriptor(
                library: library,
                fragmentFunction: "fragmentRGB",
                pixelFormat: mode.drawablePixelFormat
            )
        )
        biPlanarPipelineState = try device.makeRenderPipelineState(
            descriptor: Self.makePipelineDescriptor(
                library: library,
                fragmentFunction: "fragmentBiPlanar",
                pixelFormat: mode.drawablePixelFormat
            )
        )
        activeDynamicRangeMode = mode
    }

    private static func makePipelineDescriptor(
        library: MTLLibrary,
        fragmentFunction: String,
        pixelFormat: MTLPixelFormat
    ) -> MTLRenderPipelineDescriptor {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.vertexFunction = library.makeFunction(name: "vertexMain")
        descriptor.fragmentFunction = library.makeFunction(name: fragmentFunction)
        return descriptor
    }
}

private extension MTLDevice {
    func makeDefaultSwiftMoonlightLibrary() throws -> MTLLibrary {
        let source = """
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
            uint outputEncoding;
            uint padding1;
        };

        struct PresentationUniform {
            float2 scale;
        };

        vertex VertexOut vertexMain(
            uint vertexID [[vertex_id]],
            const device float4* vertices [[buffer(0)]],
            constant PresentationUniform& presentation [[buffer(1)]]
        ) {
            VertexOut out;
            float4 entry = vertices[vertexID];
            out.position = float4(entry.xy * presentation.scale, 0.0, 1.0);
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

        float3 srgbToLinear(float3 srgb) {
            srgb = saturate(srgb);
            float3 low = srgb / 12.92;
            float3 high = pow((srgb + 0.055) / 1.055, float3(2.4));
            return select(high, low, srgb <= float3(0.04045));
        }

        float3 bt2020LinearToBT709Linear(float3 rgb) {
            // PQ decode produces linear BT.2020 for HDR streams, but the
            // current layer target is SDR BGRA. Convert gamut before encoding.
            return float3(
                dot(float3(1.6605, -0.5876, -0.0728), rgb),
                dot(float3(-0.1246, 1.1329, -0.0083), rgb),
                dot(float3(-0.0182, -0.1006, 1.1187), rgb)
            );
        }

        float3 toneMapHDRToSDR(float3 nits) {
            // Preserve SDR-range values while rolling off HDR highlights
            // instead of clipping all content above reference white.
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

        float3 pqToExtendedLinearSRGB(float3 pq, uint ycbcrMatrix) {
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
            return max(nits / 203.0, float3(0.0));
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

        float3 hlgToExtendedLinearSRGB(float3 hlg, uint ycbcrMatrix) {
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
            return max(nits / 203.0, float3(0.0));
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
                rgb = conversion.outputEncoding == 1
                    ? pqToExtendedLinearSRGB(rgb, conversion.ycbcrMatrix)
                    : pqToSRGB(rgb, conversion.ycbcrMatrix);
            } else if (conversion.transferFunction == 2) {
                rgb = conversion.outputEncoding == 1
                    ? hlgToExtendedLinearSRGB(rgb, conversion.ycbcrMatrix)
                    : hlgToSRGB(rgb, conversion.ycbcrMatrix);
            } else if (conversion.outputEncoding == 1) {
                rgb = srgbToLinear(rgb);
            }

            if (conversion.outputEncoding == 1) {
                return float4(max(rgb, float3(0.0)), 1.0);
            }
            return float4(saturate(rgb), 1.0);
        }
        """

        do {
            return try makeLibrary(source: source, options: nil)
        } catch {
            throw MoonlightError(.unsupportedOperation, message: "Failed to compile Metal shader library: \(error)")
        }
    }
}
#endif
