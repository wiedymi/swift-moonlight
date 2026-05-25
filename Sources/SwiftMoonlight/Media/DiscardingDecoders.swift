import CoreGraphics
import Foundation

public actor DiscardingVideoDecoder: VideoDecoder {
    private var format: VideoFormat?

    public init() {}

    public func configure(format: VideoFormat) async throws {
        self.format = format
    }

    public func decode(_ frame: EncodedVideoFrame) async throws -> [DecodedVideoFrame] {
        guard let format else {
            throw MoonlightError(.unsupportedOperation, message: "Video decoder is not configured")
        }
        return [
            DecodedVideoFrame(
                timestamp: frame.timestamp,
                dimensions: format.dimensions,
                bytes: Data()
            )
        ]
    }

    public func flush() async throws -> [DecodedVideoFrame] {
        []
    }
}

public actor SilenceAudioDecoder: AudioDecoder {
    private var format: AudioFormat?

    public init() {}

    public func configure(format: AudioFormat) async throws {
        self.format = format
    }

    public func decode(_ packet: EncodedAudioPacket) async throws -> PCMBuffer {
        guard let format else {
            throw MoonlightError(.unsupportedOperation, message: "Audio decoder is not configured")
        }
        let frameCount = max(Int(format.sampleRate / 100), 1)
        return PCMBuffer(
            sampleRate: format.sampleRate,
            channelCount: format.channelCount,
            frameCount: frameCount,
            bytesPerFrame: max(format.channelCount * 2, 2),
            data: Data(repeating: 0, count: frameCount * max(format.channelCount * 2, 2))
        )
    }
}
