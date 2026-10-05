import Foundation

public actor MediaPipeline {
    private let clock: any Clock
    private var videoDecoder: (any VideoDecoder)?
    private var renderer: (any FrameRenderer)?
    private var audioDecoder: (any AudioDecoder)?
    private var audioSink: (any AudioSink)?
    private var videoFormat: VideoFormat?
    private var audioFormat: AudioFormat?
    private var stats = MediaPipelineStats()
    private var cachedVideoParameterSets: [Data] = []
    private var totalVideoDecodeLatencyMs = 0.0
    private var videoDecodeSamples = 0
    private var totalVideoQueueLatencyMs = 0.0
    private var videoQueueSamples = 0
    private var totalVideoRenderSubmissionLatencyMs = 0.0
    private var videoRenderSubmissionSamples = 0
    private var totalHostProcessingLatencyMs = 0.0
    private var hostProcessingLatencySamples = 0
    private var totalAudioDecodeLatencyMs = 0.0
    private var audioDecodeSamples = 0

    public init(clock: any Clock = SystemClock()) {
        self.clock = clock
    }

    public func attachVideoDecoder(_ decoder: any VideoDecoder) async throws {
        videoDecoder = decoder
        if let videoFormat {
            try await decoder.configure(format: videoFormat)
        }
    }

    public func attachRenderer(_ renderer: any FrameRenderer) async throws {
        self.renderer = renderer
        if let videoFormat {
            try await renderer.prepare(format: videoFormat)
        }
    }

    public func attachAudioDecoder(_ decoder: any AudioDecoder) async throws {
        audioDecoder = decoder
        if let audioFormat {
            try await decoder.configure(format: audioFormat)
        }
    }

    public func attachAudioSink(_ sink: any AudioSink) async throws {
        audioSink = sink
        if let audioFormat {
            try await sink.prepare(format: audioFormat)
        }
    }

    public func configureVideo(format: VideoFormat) async throws {
        videoFormat = format
        cachedVideoParameterSets = []
        if let videoDecoder {
            try await videoDecoder.configure(format: format)
        }
        if let renderer {
            try await renderer.prepare(format: format)
        }
    }

    public func configureAudio(format: AudioFormat) async throws {
        audioFormat = format
        if let audioDecoder {
            try await audioDecoder.configure(format: format)
        }
        if let audioSink {
            try await audioSink.prepare(format: format)
        }
    }

    public func ingestVideo(_ frame: EncodedVideoFrame, queuedAt: ContinuousClock.Instant? = nil) async throws {
        if let queuedAt {
            let latencyMs = Self.milliseconds(queuedAt.duration(to: ContinuousClock().now))
            totalVideoQueueLatencyMs += latencyMs
            videoQueueSamples += 1
            stats.averageVideoQueueLatencyMs = totalVideoQueueLatencyMs / Double(videoQueueSamples)
            stats.maxVideoQueueLatencyMs = max(stats.maxVideoQueueLatencyMs ?? 0, latencyMs)
        }
        guard let videoDecoder else {
            throw MoonlightError(.unsupportedOperation, message: "No video decoder attached")
        }

        var decodeFrame = frame
        let observedParameterSets = frame.parameterSets.isEmpty
            ? AnnexBBitstream.codecParameterSets(from: frame.payload, codec: frame.codec)
            : frame.parameterSets
        if !observedParameterSets.isEmpty {
            cachedVideoParameterSets = observedParameterSets
            decodeFrame.parameterSets = observedParameterSets
        } else if !cachedVideoParameterSets.isEmpty {
            decodeFrame.parameterSets = cachedVideoParameterSets
        }

        if let hostProcessingLatencyMs = decodeFrame.hostProcessingLatencyMs {
            recordHostProcessingLatency(hostProcessingLatencyMs)
        }

        let decodeStartedAt = clock.now()
        let decodedFrames = try await videoDecoder.decode(decodeFrame)
        let decodeFinishedAt = clock.now()
        recordVideoDecodeLatency(from: decodeStartedAt, to: decodeFinishedAt)
        stats.decodedVideoFrames += decodedFrames.count

        await submitToRenderer(decodedFrames)
    }

    public func flushVideo() async throws {
        guard let videoDecoder else {
            return
        }

        let decodedFrames = try await videoDecoder.flush()
        stats.decodedVideoFrames += decodedFrames.count

        await submitToRenderer(decodedFrames)
    }

    public func ingestAudio(_ packet: EncodedAudioPacket) async throws {
        guard let audioDecoder else {
            throw MoonlightError(.unsupportedOperation, message: "No audio decoder attached")
        }

        if packet.isConcealment {
            stats.audioUnderrunEvents += 1
        }

        let decodeStartedAt = clock.now()
        let buffer = try await audioDecoder.decode(packet)
        let decodeFinishedAt = clock.now()
        recordAudioDecodeLatency(from: decodeStartedAt, to: decodeFinishedAt)
        stats.decodedAudioBuffers += 1

        if let audioSink {
            if await audioSink.play(buffer) == .accepted {
                stats.playedAudioBuffers += 1
            }
        }
    }

    public func teardown() async {
        let audioSink = self.audioSink
        let renderer = self.renderer
        // In-flight decodes must not restart playback after teardown.
        self.audioSink = nil
        self.renderer = nil
        audioDecoder = nil
        videoDecoder = nil
        await audioSink?.teardown()
        await renderer?.teardown()
    }

    public func snapshot() -> MediaPipelineStats {
        stats
    }

    private func submitToRenderer(_ frames: [DecodedVideoFrame]) async {
        guard let renderer else { return }
        for frame in frames {
            let startedAt = ContinuousClock().now
            await renderer.render(frame)
            let latencyMs = Self.milliseconds(startedAt.duration(to: ContinuousClock().now))
            totalVideoRenderSubmissionLatencyMs += latencyMs
            videoRenderSubmissionSamples += 1
            stats.averageVideoRenderSubmissionLatencyMs = totalVideoRenderSubmissionLatencyMs / Double(videoRenderSubmissionSamples)
            stats.maxVideoRenderSubmissionLatencyMs = max(stats.maxVideoRenderSubmissionLatencyMs ?? 0, latencyMs)
        }
        stats.renderedVideoFrames += frames.count
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return max(0, Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15)
    }

    private func recordVideoDecodeLatency(from startedAt: Date, to finishedAt: Date) {
        let latencyMs = max(0, finishedAt.timeIntervalSince(startedAt) * 1000)
        totalVideoDecodeLatencyMs += latencyMs
        videoDecodeSamples += 1
        stats.averageVideoDecodeLatencyMs = totalVideoDecodeLatencyMs / Double(videoDecodeSamples)
        stats.maxVideoDecodeLatencyMs = max(stats.maxVideoDecodeLatencyMs ?? 0, latencyMs)
    }

    private func recordHostProcessingLatency(_ latencyMs: Double) {
        totalHostProcessingLatencyMs += latencyMs
        hostProcessingLatencySamples += 1
        stats.averageHostProcessingLatencyMs = totalHostProcessingLatencyMs / Double(hostProcessingLatencySamples)
        stats.maxHostProcessingLatencyMs = max(stats.maxHostProcessingLatencyMs ?? 0, latencyMs)
    }

    private func recordAudioDecodeLatency(from startedAt: Date, to finishedAt: Date) {
        let latencyMs = max(0, finishedAt.timeIntervalSince(startedAt) * 1000)
        totalAudioDecodeLatencyMs += latencyMs
        audioDecodeSamples += 1
        stats.averageAudioDecodeLatencyMs = totalAudioDecodeLatencyMs / Double(audioDecodeSamples)
        stats.maxAudioDecodeLatencyMs = max(stats.maxAudioDecodeLatencyMs ?? 0, latencyMs)
    }
}
