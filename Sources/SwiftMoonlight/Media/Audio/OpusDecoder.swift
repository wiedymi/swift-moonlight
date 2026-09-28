#if canImport(COpus)
import COpus
import Foundation

private final class OpusDecoderBox: @unchecked Sendable {
    var decoder: OpaquePointer?

    deinit {
        if let decoder {
            opus_multistream_decoder_destroy(decoder)
        }
    }
}

public actor OpusDecoder: AudioDecoder {
    private let decoderBox = OpusDecoderBox()
    private var format: AudioFormat?

    public init() {}

    public func configure(format: AudioFormat) async throws {
        let config = try resolveConfiguration(from: format)
        var errorCode: Int32 = OPUS_OK
        let decoder: OpaquePointer? = config.mapping.withUnsafeBufferPointer { mapping in
            let mappingPointer = mapping.baseAddress!
            return opus_multistream_decoder_create(
                Int32(config.sampleRate),
                Int32(config.channelCount),
                Int32(config.streams),
                Int32(config.coupledStreams),
                mappingPointer,
                &errorCode
            )
        }

        guard errorCode == OPUS_OK, let decoder else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to create Opus decoder: \(errorCode)")
        }

        if let existing = decoderBox.decoder {
            opus_multistream_decoder_destroy(existing)
        }
        decoderBox.decoder = decoder
        self.format = AudioFormat(
            sampleRate: format.sampleRate,
            channelCount: format.channelCount,
            opusConfiguration: config
        )
    }

    public func decode(_ packet: EncodedAudioPacket) async throws -> PCMBuffer {
        guard let decoder = decoderBox.decoder,
              let format
        else {
            throw MoonlightError(.unsupportedOperation, message: "Opus decoder used before configure(format:)")
        }

        let config = try resolveConfiguration(from: format)
        let maxFrameCount = max(config.samplesPerFrame, 5760)
        let outputSampleCount = maxFrameCount * config.channelCount
        var pcm = [Int16](repeating: 0, count: outputSampleCount)

        let decodedFrameCount: Int32
        if packet.isConcealment || packet.payload.isEmpty {
            let result = opus_multistream_decode(
                decoder,
                nil,
                0,
                &pcm,
                Int32(maxFrameCount),
                0
            )
            guard result >= 0 else {
                throw MoonlightError(.unsupportedOperation, message: "Opus concealment decode failed: \(result)")
            }
            decodedFrameCount = result
        } else {
            decodedFrameCount = try packet.payload.withUnsafeBytes { packetBytes in
                let payloadPointer = packetBytes.bindMemory(to: UInt8.self).baseAddress
                let result = opus_multistream_decode(
                    decoder,
                    payloadPointer,
                    Int32(packet.payload.count),
                    &pcm,
                    Int32(maxFrameCount),
                    0
                )
                guard result >= 0 else {
                    let prefix = packet.payload.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
                    throw MoonlightError(
                        .unsupportedOperation,
                        message: "Opus decode failed: \(result) [len=\(packet.payload.count), concealment=\(packet.isConcealment), prefix=\(prefix)]"
                    )
                }
                return result
            }
        }

        let byteCount = Int(decodedFrameCount) * config.channelCount * MemoryLayout<Int16>.size
        let data = pcm.withUnsafeBytes { rawBytes in
            Data(rawBytes.prefix(byteCount))
        }

        return PCMBuffer(
            sampleRate: config.sampleRate,
            channelCount: config.channelCount,
            frameCount: Int(decodedFrameCount),
            bytesPerFrame: config.channelCount * MemoryLayout<Int16>.size,
            data: data
        )
    }

    private func resolveConfiguration(from format: AudioFormat) throws -> OpusStreamConfiguration {
        if let config = format.opusConfiguration {
            return config
        }

        if format.channelCount == 2 {
            return .stereo(sampleRate: format.sampleRate)
        }

        throw MoonlightError(.unsupportedOperation, message: "Opus multistream configuration is required for \(format.channelCount)-channel audio")
    }
}
#endif
