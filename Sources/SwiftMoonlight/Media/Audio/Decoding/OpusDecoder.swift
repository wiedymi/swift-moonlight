#if canImport(AudioToolbox)
import AudioToolbox
import Foundation

public actor OpusDecoder: AudioDecoder {
    private var converter: OpusConverter?

    public init() {}

    public func configure(format: AudioFormat) async throws {
        let config: OpusStreamConfiguration
        if let provided = format.opusConfiguration {
            config = provided
        } else if format.channelCount == 2 {
            config = .stereo(sampleRate: format.sampleRate)
        } else {
            throw failure("Opus multistream configuration is required")
        }
        guard [8_000, 12_000, 16_000, 24_000, 48_000].contains(config.sampleRate),
              config.sampleRate == format.sampleRate,
              config.channelCount == format.channelCount,
              (1...8).contains(config.channelCount),
              (1...config.channelCount).contains(config.streams),
              (0...config.streams).contains(config.coupledStreams),
              config.mapping.count == config.channelCount,
              config.mapping.allSatisfy({ $0 == 255 || Int($0) < config.streams + config.coupledStreams }),
              config.samplesPerFrame > 0,
              config.samplesPerFrame <= config.sampleRate * 120 / 1000
        else { throw failure("Invalid Opus configuration") }

        var input = AudioStreamBasicDescription(
            mSampleRate: Double(config.sampleRate), mFormatID: kAudioFormatOpus,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 0,
            mBytesPerFrame: 0, mChannelsPerFrame: UInt32(config.channelCount),
            mBitsPerChannel: 0, mReserved: 0
        )
        let bytesPerFrame = UInt32(config.channelCount * MemoryLayout<Int16>.size)
        var output = AudioStreamBasicDescription(
            mSampleRate: Double(config.sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame, mChannelsPerFrame: UInt32(config.channelCount),
            mBitsPerChannel: 16, mReserved: 0
        )
        var reference: AudioConverterRef?
        let status = AudioConverterNew(&input, &output, &reference)
        guard status == noErr, let reference else {
            throw failure("Apple Opus decoder creation failed: \(status)")
        }
        let candidate = OpusConverter(reference: reference, configuration: config)
        // OpusHead carries the negotiated mapping in output order. Zero pre-skip
        // and zero converter priming preserve the first live packet's full duration.
        var cookie = Data("OpusHead".utf8)
        cookie.append(contentsOf: [1, UInt8(config.channelCount), 0, 0])
        var sampleRate = UInt32(config.sampleRate).littleEndian
        withUnsafeBytes(of: &sampleRate) { cookie.append(contentsOf: $0) }
        cookie.append(contentsOf: [0, 0, 1, UInt8(config.streams), UInt8(config.coupledStreams)])
        cookie.append(contentsOf: config.mapping)
        let cookieStatus = cookie.withUnsafeBytes {
            AudioConverterSetProperty(reference, kAudioConverterDecompressionMagicCookie, UInt32(cookie.count), $0.baseAddress!)
        }
        guard cookieStatus == noErr else { throw failure("Apple Opus configuration failed: \(cookieStatus)") }
        var prime = AudioConverterPrimeInfo(leadingFrames: 0, trailingFrames: 0)
        let primeStatus = AudioConverterSetProperty(
            reference, kAudioConverterPrimeInfo, UInt32(MemoryLayout<AudioConverterPrimeInfo>.size), &prime
        )
        guard primeStatus == noErr else { throw failure("Apple Opus priming setup failed: \(primeStatus)") }
        converter = candidate
    }

    public func decode(_ packet: EncodedAudioPacket) async throws -> PCMBuffer {
        guard let converter else { throw failure("Opus decoder used before configure(format:)") }
        let config = converter.configuration
        let payload = packet.isConcealment ? Data() : packet.payload
        guard payload.count <= Int(UInt32.max) else { throw failure("Opus packet is too large") }
        let frameCount = payload.isEmpty ? config.samplesPerFrame : try Self.frameCount(payload, sampleRate: config.sampleRate)
        let bytesPerFrame = config.channelCount * MemoryLayout<Int16>.size
        var pcm = Data(count: frameCount * bytesPerFrame)
        var outputFrames = UInt32(frameCount)
        var input = OpusConverterInput(
            packet: OpusPacketStorage(payload: payload, frameCount: frameCount, channelCount: config.channelCount),
            converter: converter
        )
        let status = withUnsafeMutablePointer(to: &input) { inputPointer in
            pcm.withUnsafeMutableBytes { outputBytes in
                var buffers = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: UInt32(config.channelCount),
                                          mDataByteSize: UInt32(outputBytes.count), mData: outputBytes.baseAddress)
                )
                return AudioConverterFillComplexBuffer(
                    converter.reference, supplyOpusPacket, inputPointer, &outputFrames, &buffers, nil
                )
            }
        }
        guard status == noErr, outputFrames == UInt32(frameCount) else {
            // Discard partial decoder state after a malformed packet.
            AudioConverterReset(converter.reference)
            converter.retainedPacket = nil
            throw failure("Apple Opus decode failed: \(status), frames: \(outputFrames)/\(frameCount)")
        }
        converter.configuration.samplesPerFrame = frameCount
        return PCMBuffer(sampleRate: config.sampleRate, channelCount: config.channelCount,
                         frameCount: frameCount, bytesPerFrame: bytesPerFrame, data: pcm)
    }

    // RFC 6716 section 3: the first stream's TOC describes every stream's duration.
    static func frameCount(_ packet: Data, sampleRate: Int) throws -> Int {
        guard sampleRate > 0, sampleRate <= 48_000, let toc = packet.first else {
            throw failure("Invalid Opus duration input")
        }
        let mode = Int((toc >> 3) & 3)
        let samples: Int
        if toc & 0x80 != 0 {
            samples = (sampleRate << mode) / 400
        } else if toc & 0x60 == 0x60 {
            samples = sampleRate / (toc & 8 != 0 ? 50 : 100)
        } else {
            samples = mode == 3 ? sampleRate * 60 / 1000 : (sampleRate << mode) / 100
        }
        let count: Int
        switch toc & 3 {
        case 0: count = 1
        case 1, 2: count = 2
        default:
            guard packet.count >= 2 else { throw failure("Truncated Opus duration header") }
            count = Int(packet[packet.startIndex + 1] & 0x3f)
        }
        let frames = samples * count
        guard count > 0, frames > 0, frames <= sampleRate * 120 / 1000 else {
            throw failure("Invalid Opus packet duration")
        }
        return frames
    }

    private static func failure(_ message: String) -> MoonlightError {
        MoonlightError(.unsupportedOperation, message: message)
    }

    private func failure(_ message: String) -> MoonlightError { Self.failure(message) }
}
#endif
