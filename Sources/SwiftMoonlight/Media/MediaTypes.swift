import CoreGraphics
import Foundation
#if canImport(CoreVideo)
import CoreVideo

// Safety invariant:
// `CVPixelBuffer` instances are only created and consumed behind decoder/renderer
// actor boundaries. The wrapper exists so `DecodedVideoFrame` can move through the
// async pipeline without leaking CoreVideo types directly into public actor state.
public final class PixelBufferBox: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer

    public init(_ pixelBuffer: CVPixelBuffer) {
        self.pixelBuffer = pixelBuffer
    }
}
#endif

public struct VideoFormat: Sendable, Equatable {
    public var codec: VideoCodec
    public var dimensions: CGSize
    public var dynamicRange: DynamicRangePreference

    public init(codec: VideoCodec, dimensions: CGSize, dynamicRange: DynamicRangePreference = .sdr) {
        self.codec = codec
        self.dimensions = dimensions
        self.dynamicRange = dynamicRange
    }
}

public struct AudioFormat: Sendable, Equatable {
    public var sampleRate: Int
    public var channelCount: Int
    public var opusConfiguration: OpusStreamConfiguration?

    public init(sampleRate: Int, channelCount: Int, opusConfiguration: OpusStreamConfiguration? = nil) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.opusConfiguration = opusConfiguration
    }
}

public struct OpusStreamConfiguration: Sendable, Equatable {
    public var sampleRate: Int
    public var channelCount: Int
    public var streams: Int
    public var coupledStreams: Int
    public var samplesPerFrame: Int
    public var mapping: [UInt8]

    public init(
        sampleRate: Int,
        channelCount: Int,
        streams: Int,
        coupledStreams: Int,
        samplesPerFrame: Int,
        mapping: [UInt8]
    ) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.streams = streams
        self.coupledStreams = coupledStreams
        self.samplesPerFrame = samplesPerFrame
        self.mapping = mapping
    }

    public static func stereo(sampleRate: Int = 48_000, samplesPerFrame: Int = 960) -> OpusStreamConfiguration {
        OpusStreamConfiguration(
            sampleRate: sampleRate,
            channelCount: 2,
            streams: 1,
            coupledStreams: 1,
            samplesPerFrame: samplesPerFrame,
            mapping: [0, 1]
        )
    }
}

public struct EncodedVideoFrame: Sendable, Equatable {
    public var timestamp: UInt64
    public var isKeyFrame: Bool
    public var codec: VideoCodec
    public var parameterSets: [Data]
    public var hostProcessingLatencyMs: Double?
    public var payload: Data

    public init(
        timestamp: UInt64,
        isKeyFrame: Bool,
        codec: VideoCodec,
        parameterSets: [Data] = [],
        hostProcessingLatencyMs: Double? = nil,
        payload: Data
    ) {
        self.timestamp = timestamp
        self.isKeyFrame = isKeyFrame
        self.codec = codec
        self.parameterSets = parameterSets
        self.hostProcessingLatencyMs = hostProcessingLatencyMs
        self.payload = payload
    }
}

public struct DecodedVideoFrame: Sendable, Equatable {
    public var timestamp: UInt64
    public var dimensions: CGSize
    public var bytes: Data?
#if canImport(CoreVideo)
    public var pixelBuffer: PixelBufferBox?
#endif

    public init(
        timestamp: UInt64,
        dimensions: CGSize,
        bytes: Data? = nil
    ) {
        self.timestamp = timestamp
        self.dimensions = dimensions
        self.bytes = bytes
#if canImport(CoreVideo)
        self.pixelBuffer = nil
#endif
    }

#if canImport(CoreVideo)
    public init(
        timestamp: UInt64,
        dimensions: CGSize,
        pixelBuffer: PixelBufferBox
    ) {
        self.timestamp = timestamp
        self.dimensions = dimensions
        self.bytes = nil
        self.pixelBuffer = pixelBuffer
    }
#endif

    public static func == (lhs: DecodedVideoFrame, rhs: DecodedVideoFrame) -> Bool {
        lhs.timestamp == rhs.timestamp &&
        lhs.dimensions == rhs.dimensions &&
        lhs.bytes == rhs.bytes &&
        lhs.pixelBufferPresence == rhs.pixelBufferPresence
    }

    private var pixelBufferPresence: Bool {
#if canImport(CoreVideo)
        pixelBuffer != nil
#else
        false
#endif
    }
}

public struct EncodedAudioPacket: Sendable, Equatable {
    public var timestamp: UInt64
    public var payload: Data
    public var isConcealment: Bool

    public init(timestamp: UInt64, payload: Data, isConcealment: Bool = false) {
        self.timestamp = timestamp
        self.payload = payload
        self.isConcealment = isConcealment
    }
}

public struct PCMBuffer: Sendable, Equatable {
    public var sampleRate: Int
    public var channelCount: Int
    public var frameCount: Int
    public var bytesPerFrame: Int
    public var data: Data

    public init(sampleRate: Int, channelCount: Int, frameCount: Int, bytesPerFrame: Int, data: Data) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.bytesPerFrame = bytesPerFrame
        self.data = data
    }
}

public final class MetalFrameResources: @unchecked Sendable {
    public let retainedObjects: [AnyObject]

    public init(retainedObjects: [AnyObject]) {
        self.retainedObjects = retainedObjects
    }
}

public protocol VideoDecoder: Sendable {
    func configure(format: VideoFormat) async throws
    func decode(_ frame: EncodedVideoFrame) async throws -> [DecodedVideoFrame]
    func flush() async throws -> [DecodedVideoFrame]
}

public protocol FrameRenderer: Sendable {
    func prepare(format: VideoFormat) async throws
    func render(_ frame: DecodedVideoFrame) async
    func teardown() async
}

public protocol AudioDecoder: Sendable {
    func configure(format: AudioFormat) async throws
    func decode(_ packet: EncodedAudioPacket) async throws -> PCMBuffer
}

public protocol AudioSink: Sendable {
    func prepare(format: AudioFormat) async throws
    func play(_ buffer: PCMBuffer) async
    func teardown() async
}

public struct MediaPipelineStats: Sendable, Equatable {
    public var decodedVideoFrames: Int
    public var renderedVideoFrames: Int
    public var decodedAudioBuffers: Int
    public var playedAudioBuffers: Int
    public var averageVideoDecodeLatencyMs: Double?
    public var maxVideoDecodeLatencyMs: Double?
    public var averageHostProcessingLatencyMs: Double?
    public var maxHostProcessingLatencyMs: Double?
    public var averageAudioDecodeLatencyMs: Double?
    public var maxAudioDecodeLatencyMs: Double?
    public var audioUnderrunEvents: Int

    public init(
        decodedVideoFrames: Int = 0,
        renderedVideoFrames: Int = 0,
        decodedAudioBuffers: Int = 0,
        playedAudioBuffers: Int = 0,
        averageVideoDecodeLatencyMs: Double? = nil,
        maxVideoDecodeLatencyMs: Double? = nil,
        averageHostProcessingLatencyMs: Double? = nil,
        maxHostProcessingLatencyMs: Double? = nil,
        averageAudioDecodeLatencyMs: Double? = nil,
        maxAudioDecodeLatencyMs: Double? = nil,
        audioUnderrunEvents: Int = 0
    ) {
        self.decodedVideoFrames = decodedVideoFrames
        self.renderedVideoFrames = renderedVideoFrames
        self.decodedAudioBuffers = decodedAudioBuffers
        self.playedAudioBuffers = playedAudioBuffers
        self.averageVideoDecodeLatencyMs = averageVideoDecodeLatencyMs
        self.maxVideoDecodeLatencyMs = maxVideoDecodeLatencyMs
        self.averageHostProcessingLatencyMs = averageHostProcessingLatencyMs
        self.maxHostProcessingLatencyMs = maxHostProcessingLatencyMs
        self.averageAudioDecodeLatencyMs = averageAudioDecodeLatencyMs
        self.maxAudioDecodeLatencyMs = maxAudioDecodeLatencyMs
        self.audioUnderrunEvents = audioUnderrunEvents
    }
}
