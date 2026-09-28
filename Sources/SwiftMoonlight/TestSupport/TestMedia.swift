import Foundation

public struct NullRenderer: FrameRenderer {
    public init() {}

    public func prepare(format: VideoFormat) async throws {
        _ = format
    }

    public func render(_ frame: DecodedVideoFrame) async {
        _ = frame
    }

    public func teardown() async {}
}

public actor RecordingRenderer: FrameRenderer {
    private var preparedFormats: [VideoFormat] = []
    private var renderedFrames: [DecodedVideoFrame] = []

    public init() {}

    public func prepare(format: VideoFormat) async throws {
        preparedFormats.append(format)
    }

    public func render(_ frame: DecodedVideoFrame) async {
        renderedFrames.append(frame)
    }

    public func teardown() async {}

    public func recordedFormats() -> [VideoFormat] {
        preparedFormats
    }

    public func recordedFrames() -> [DecodedVideoFrame] {
        renderedFrames
    }
}

public struct NullAudioSink: AudioSink {
    public init() {}

    public func prepare(format: AudioFormat) async throws {
        _ = format
    }

    public func play(_ buffer: PCMBuffer) async {
        _ = buffer
    }

    public func teardown() async {}
}

public actor RecordingAudioSink: AudioSink {
    private var preparedFormats: [AudioFormat] = []
    private var playedBuffers: [PCMBuffer] = []

    public init() {}

    public func prepare(format: AudioFormat) async throws {
        preparedFormats.append(format)
    }

    public func play(_ buffer: PCMBuffer) async {
        playedBuffers.append(buffer)
    }

    public func teardown() async {}

    public func recordedFormats() -> [AudioFormat] {
        preparedFormats
    }

    public func recordedBuffers() -> [PCMBuffer] {
        playedBuffers
    }
}

public actor RecordingVideoDecoder: VideoDecoder {
    private var configuredFormats: [VideoFormat] = []
    private var decodedInputs: [EncodedVideoFrame] = []
    private var decodeOutputs: [[DecodedVideoFrame]]
    private var flushOutputs: [[DecodedVideoFrame]]

    public init(
        decodeOutputs: [[DecodedVideoFrame]] = [],
        flushOutputs: [[DecodedVideoFrame]] = []
    ) {
        self.decodeOutputs = decodeOutputs
        self.flushOutputs = flushOutputs
    }

    public func configure(format: VideoFormat) async throws {
        configuredFormats.append(format)
    }

    public func decode(_ frame: EncodedVideoFrame) async throws -> [DecodedVideoFrame] {
        decodedInputs.append(frame)
        guard !decodeOutputs.isEmpty else {
            return []
        }
        return decodeOutputs.removeFirst()
    }

    public func flush() async throws -> [DecodedVideoFrame] {
        guard !flushOutputs.isEmpty else {
            return []
        }
        return flushOutputs.removeFirst()
    }

    public func recordedFormats() -> [VideoFormat] {
        configuredFormats
    }

    public func recordedInputs() -> [EncodedVideoFrame] {
        decodedInputs
    }
}

public actor FailingVideoDecoder: VideoDecoder {
    private var configuredFormats: [VideoFormat] = []
    private let configureError: Error?
    private let error: Error
    private let failAfterDecodeCount: Int?
    private var decodeCount = 0

    public init(
        configureError: Error? = nil,
        error: Error = MoonlightError(.unsupportedOperation, message: "Decoder failure"),
        failAfterDecodeCount: Int? = 0
    ) {
        self.configureError = configureError
        self.error = error
        self.failAfterDecodeCount = failAfterDecodeCount
    }

    public func configure(format: VideoFormat) async throws {
        configuredFormats.append(format)
        if let configureError {
            throw configureError
        }
    }

    public func decode(_ frame: EncodedVideoFrame) async throws -> [DecodedVideoFrame] {
        _ = frame
        let shouldFail: Bool
        if let failAfterDecodeCount {
            shouldFail = decodeCount >= failAfterDecodeCount
        } else {
            shouldFail = false
        }
        decodeCount += 1

        if shouldFail {
            throw error
        }

        return []
    }

    public func flush() async throws -> [DecodedVideoFrame] {
        []
    }

    public func recordedFormats() -> [VideoFormat] {
        configuredFormats
    }
}

public actor RecordingAudioDecoder: AudioDecoder {
    private var configuredFormats: [AudioFormat] = []
    private var decodedInputs: [EncodedAudioPacket] = []
    private var outputs: [PCMBuffer]

    public init(outputs: [PCMBuffer] = []) {
        self.outputs = outputs
    }

    public func configure(format: AudioFormat) async throws {
        configuredFormats.append(format)
    }

    public func decode(_ packet: EncodedAudioPacket) async throws -> PCMBuffer {
        decodedInputs.append(packet)
        if !outputs.isEmpty {
            return outputs.removeFirst()
        }

        return PCMBuffer(
            sampleRate: configuredFormats.last?.sampleRate ?? 48_000,
            channelCount: configuredFormats.last?.channelCount ?? 2,
            frameCount: 0,
            bytesPerFrame: 0,
            data: Data()
        )
    }

    public func recordedFormats() -> [AudioFormat] {
        configuredFormats
    }

    public func recordedInputs() -> [EncodedAudioPacket] {
        decodedInputs
    }
}
