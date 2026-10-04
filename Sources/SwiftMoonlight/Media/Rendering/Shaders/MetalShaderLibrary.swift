#if canImport(Metal) && canImport(QuartzCore)
import Metal

extension MTLDevice {
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
            if (any(in.texCoord < 0.0) || any(in.texCoord > 1.0)) { discard_fragment(); }
            constexpr sampler textureSampler(address::clamp_to_edge, mag_filter::linear, min_filter::linear);
            return colorTexture.sample(textureSampler, in.texCoord);
        }


        fragment float4 fragmentPresentation(
            VertexOut in [[stage_in]], texture2d<float> picture [[texture(0)]],
            texture2d<float> background [[texture(1)]],
            constant float4& effect [[buffer(0)]], constant float2& backgroundScale [[buffer(1)]]
        ) {
            constexpr sampler s(address::clamp_to_edge, mag_filter::linear, min_filter::linear);
            float2 uv = (in.texCoord - 0.5) / effect.xy + 0.5;
            bool inside = all(uv >= 0.0) && all(uv <= 1.0);
            float4 sharp = inside ? picture.sample(s, uv) : float4(0.0, 0.0, 0.0, 1.0);
            if (effect.w == 0.0 || (inside && effect.z == 1.0)) { return sharp; }
            float2 bgUV = (in.texCoord - 0.5) / backgroundScale + 0.5;
            float4 blurred = background.sample(s, bgUV);
            blurred.rgb *= mix(0.25, 0.12, smoothstep(0.0, 1.0, in.texCoord.y));
            blurred.a = 1.0;
            return mix(blurred, sharp, inside ? effect.z : 0.0);
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
            if (any(in.texCoord < 0.0) || any(in.texCoord > 1.0)) { discard_fragment(); }
            constexpr sampler textureSampler(address::clamp_to_edge, mag_filter::linear, min_filter::linear);
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
