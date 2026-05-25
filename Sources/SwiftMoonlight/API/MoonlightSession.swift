import Foundation

public enum SessionEvent: Sendable {
    case stateChanged(SessionState)
    case videoFormatChanged(VideoFormat)
    case audioFormatChanged(AudioFormat)
    case hdrModeChanged(HDRModeUpdate)
    case controllerFeedback(ControllerFeedback)
    case warning(MoonlightWarning)
    case failed(MoonlightError)
}

public actor MoonlightSession: InputSending {
    private static let inputMetricsThrottleInterval: TimeInterval = 0.1

    public let events: AsyncStream<SessionEvent>
    public let metrics: AsyncStream<SessionMetricsSnapshot>

    private let eventContinuation: AsyncStream<SessionEvent>.Continuation
    private let metricsContinuation: AsyncStream<SessionMetricsSnapshot>.Continuation

    private let mediaPipeline: MediaPipeline
    private var renderer: (any FrameRenderer)?
    private var videoDecoder: (any VideoDecoder)?
    private var audioDecoder: (any AudioDecoder)?
    private var audioSink: (any AudioSink)?
    private var inputSender: (any InputSending)?
    private var controllerFeedbackSink: (any ControllerFeedbackSink)?
    private var snapshot = SessionMetricsSnapshot()
    private var lifecycle = SessionLifecycleMachine(initialState: .connecting)
    private var metricsForwardingTask: Task<Void, Never>?
    private var primedSockets: ChannelSocketSet?
    private var lastInputMetricsYieldAt: Date?
    public private(set) var negotiatedSession: NegotiatedSession?

    public init(
        negotiatedSession: NegotiatedSession? = nil,
        primedSockets: ChannelSocketSet? = nil,
        clock: any Clock = SystemClock()
    ) {
        let eventStream = AsyncStream.makeStream(of: SessionEvent.self)
        self.events = eventStream.stream
        self.eventContinuation = eventStream.continuation

        let metricsStream = AsyncStream.makeStream(of: SessionMetricsSnapshot.self)
        self.metrics = metricsStream.stream
        self.metricsContinuation = metricsStream.continuation
        self.mediaPipeline = MediaPipeline(clock: clock)

        self.negotiatedSession = negotiatedSession
        self.primedSockets = primedSockets

        eventContinuation.yield(.stateChanged(.connecting))
        if let negotiatedSession {
            snapshot.establishedChannelCount = negotiatedSession.channels.filter(\.isConnected).count
            if let videoFormat = negotiatedSession.videoFormat {
                eventContinuation.yield(.videoFormatChanged(videoFormat))
            }
            if let audioFormat = negotiatedSession.audioFormat {
                eventContinuation.yield(.audioFormatChanged(audioFormat))
            }
            try? lifecycle.transition(to: .streaming)
            eventContinuation.yield(.stateChanged(.streaming))
        }
        metricsContinuation.yield(snapshot)
    }

    public var currentState: SessionState {
        lifecycle.state
    }

    public func attachRenderer(_ renderer: any FrameRenderer) async throws {
        self.renderer = renderer
        try await mediaPipeline.attachRenderer(renderer)
        snapshot.rendererAttachments += 1
        metricsContinuation.yield(snapshot)
    }

    public func attachVideoDecoder(_ decoder: any VideoDecoder) async throws {
        videoDecoder = decoder
        try await mediaPipeline.attachVideoDecoder(decoder)
    }

    public func attachAudioDecoder(_ decoder: any AudioDecoder) async throws {
        audioDecoder = decoder
        try await mediaPipeline.attachAudioDecoder(decoder)
    }

    public func attachAudioSink(_ sink: any AudioSink) async throws {
        self.audioSink = sink
        try await mediaPipeline.attachAudioSink(sink)
        snapshot.audioSinkAttachments += 1
        metricsContinuation.yield(snapshot)
    }

    public func attachInputSender(_ sender: any InputSending) {
        inputSender = sender
    }

    public func attachControllerFeedbackSink(_ sink: (any ControllerFeedbackSink)?) {
        controllerFeedbackSink = sink
    }

    public func attachMetricsSink(_ sink: any MetricsSink) {
        metricsForwardingTask?.cancel()
        let stream = metrics
        metricsForwardingTask = Task {
            for await snapshot in stream {
                await sink.record(snapshot)
            }
        }
    }

    public func currentMetricsSnapshot() -> SessionMetricsSnapshot {
        snapshot
    }

    public func configureVideo(format: VideoFormat) async throws {
        try await mediaPipeline.configureVideo(format: format)
        eventContinuation.yield(.videoFormatChanged(format))
    }

    public func configureAudio(format: AudioFormat) async throws {
        try await mediaPipeline.configureAudio(format: format)
        eventContinuation.yield(.audioFormatChanged(format))
    }

    public func receive(_ frame: EncodedVideoFrame) async throws {
        try await mediaPipeline.ingestVideo(frame)
        await syncMediaPipelineMetrics()
    }

    public func receive(_ packet: EncodedAudioPacket) async throws {
        try await mediaPipeline.ingestAudio(packet)
        await syncMediaPipelineMetrics()
    }

    func mediaPipelineHandle() -> MediaPipeline {
        mediaPipeline
    }

    func takePrimedSockets() -> ChannelSocketSet? {
        defer { primedSockets = nil }
        return primedSockets
    }

    public func receive(controllerFeedback: ControllerFeedback) async {
        eventContinuation.yield(.controllerFeedback(controllerFeedback))
        guard let controllerFeedbackSink else {
            return
        }

        do {
            try await controllerFeedbackSink.apply(controllerFeedback)
        } catch {
            let message = (error as? MoonlightError)?.message ?? String(describing: error)
            eventContinuation.yield(.warning(.init("Controller feedback sink failed: \(message)")))
        }
    }

    public func receive(hdrMode update: HDRModeUpdate) {
        eventContinuation.yield(.hdrModeChanged(update))
    }

    public func warn(_ warning: MoonlightWarning) {
        eventContinuation.yield(.warning(warning))
    }

    public func fail(_ error: MoonlightError) {
        eventContinuation.yield(.failed(error))
    }

    public func updateRuntimeMetrics(
        sessionOpenDurationMs: Int? = nil,
        controlRoundTripTimeMs: Int? = nil,
        controlRoundTripTimeVarianceMs: Int? = nil,
        controlPacketLossRatio: Double? = nil,
        controlPacketLossVarianceRatio: Double? = nil,
        controlMessagesObserved: Int? = nil,
        videoPacketsObserved: Int? = nil,
        audioPacketsObserved: Int? = nil,
        audioConcealmentPackets: Int? = nil,
        missingVideoPackets: Int? = nil,
        missingAudioPackets: Int? = nil,
        reorderedVideoPackets: Int? = nil,
        reorderedAudioPackets: Int? = nil,
        videoDiscontinuityEvents: Int? = nil,
        videoFrameFECStatusReports: Int? = nil,
        recoverableVideoDecodeFailures: Int? = nil,
        reconnectAttempts: Int? = nil,
        decodedVideoFrames: Int? = nil,
        renderedVideoFrames: Int? = nil,
        decodedAudioBuffers: Int? = nil,
        playedAudioBuffers: Int? = nil,
        averageVideoDecodeLatencyMs: Double? = nil,
        maxVideoDecodeLatencyMs: Double? = nil,
        averageHostProcessingLatencyMs: Double? = nil,
        maxHostProcessingLatencyMs: Double? = nil,
        averageAudioDecodeLatencyMs: Double? = nil,
        maxAudioDecodeLatencyMs: Double? = nil,
        audioUnderrunEvents: Int? = nil,
        unexpectedDisconnect: Bool? = nil
    ) {
        if let sessionOpenDurationMs {
            snapshot.sessionOpenDurationMs = sessionOpenDurationMs
        }
        if let controlRoundTripTimeMs {
            snapshot.controlRoundTripTimeMs = controlRoundTripTimeMs
        }
        if let controlRoundTripTimeVarianceMs {
            snapshot.controlRoundTripTimeVarianceMs = controlRoundTripTimeVarianceMs
        }
        if let controlPacketLossRatio {
            snapshot.controlPacketLossRatio = controlPacketLossRatio
        }
        if let controlPacketLossVarianceRatio {
            snapshot.controlPacketLossVarianceRatio = controlPacketLossVarianceRatio
        }
        if let controlMessagesObserved {
            snapshot.controlMessagesObserved = controlMessagesObserved
        }
        if let videoPacketsObserved {
            snapshot.videoPacketsObserved = videoPacketsObserved
        }
        if let audioPacketsObserved {
            snapshot.audioPacketsObserved = audioPacketsObserved
        }
        if let audioConcealmentPackets {
            snapshot.audioConcealmentPackets = audioConcealmentPackets
        }
        if let missingVideoPackets {
            snapshot.missingVideoPackets = missingVideoPackets
        }
        if let missingAudioPackets {
            snapshot.missingAudioPackets = missingAudioPackets
        }
        if let reorderedVideoPackets {
            snapshot.reorderedVideoPackets = reorderedVideoPackets
        }
        if let reorderedAudioPackets {
            snapshot.reorderedAudioPackets = reorderedAudioPackets
        }
        if let videoDiscontinuityEvents {
            snapshot.videoDiscontinuityEvents = videoDiscontinuityEvents
        }
        if let videoFrameFECStatusReports {
            snapshot.videoFrameFECStatusReports = videoFrameFECStatusReports
        }
        if let recoverableVideoDecodeFailures {
            snapshot.recoverableVideoDecodeFailures = recoverableVideoDecodeFailures
        }
        if let reconnectAttempts {
            snapshot.reconnectAttempts = reconnectAttempts
        }
        if let decodedVideoFrames {
            snapshot.decodedVideoFrames = decodedVideoFrames
        }
        if let renderedVideoFrames {
            snapshot.renderedVideoFrames = renderedVideoFrames
        }
        if let decodedAudioBuffers {
            snapshot.decodedAudioBuffers = decodedAudioBuffers
        }
        if let playedAudioBuffers {
            snapshot.playedAudioBuffers = playedAudioBuffers
        }
        if let averageVideoDecodeLatencyMs {
            snapshot.averageVideoDecodeLatencyMs = averageVideoDecodeLatencyMs
        }
        if let maxVideoDecodeLatencyMs {
            snapshot.maxVideoDecodeLatencyMs = maxVideoDecodeLatencyMs
        }
        if let averageHostProcessingLatencyMs {
            snapshot.averageHostProcessingLatencyMs = averageHostProcessingLatencyMs
        }
        if let maxHostProcessingLatencyMs {
            snapshot.maxHostProcessingLatencyMs = maxHostProcessingLatencyMs
        }
        if let averageAudioDecodeLatencyMs {
            snapshot.averageAudioDecodeLatencyMs = averageAudioDecodeLatencyMs
        }
        if let maxAudioDecodeLatencyMs {
            snapshot.maxAudioDecodeLatencyMs = maxAudioDecodeLatencyMs
        }
        if let audioUnderrunEvents {
            snapshot.audioUnderrunEvents = audioUnderrunEvents
        }
        if let unexpectedDisconnect {
            snapshot.unexpectedDisconnect = unexpectedDisconnect
        }
        metricsContinuation.yield(snapshot)
    }

    public func send(_ event: InputEvent) async throws {
        if lifecycle.state == .stopping || lifecycle.state == .stopped {
            throw MoonlightError(.invalidStateTransition, message: "Cannot send input after stop")
        }

        if let inputSender {
            try await inputSender.send(event)
        }
        snapshot.inputEventsSent += 1
        await syncInputSenderMetrics()
        let now = Date()
        if let lastInputMetricsYieldAt,
           now.timeIntervalSince(lastInputMetricsYieldAt) < Self.inputMetricsThrottleInterval
        {
            return
        }

        lastInputMetricsYieldAt = now
        metricsContinuation.yield(snapshot)
    }

    public func flushPendingInput() async throws {
        if lifecycle.state == .stopping || lifecycle.state == .stopped {
            throw MoonlightError(.invalidStateTransition, message: "Cannot flush input after stop")
        }

        try await flushPendingInputIfPossible()
        await syncInputSenderMetrics()
        metricsContinuation.yield(snapshot)
    }

    private func flushPendingInputIfPossible() async throws {
        guard let flushingInputSender = inputSender as? any InputFlushing else {
            return
        }

        try await flushingInputSender.flushPendingInput()
    }

    private func syncInputSenderMetrics() async {
        guard let reportingInputSender = inputSender as? any InputMetricsReporting else {
            return
        }

        let inputMetrics = await reportingInputSender.snapshotInputMetrics()
        snapshot.inputPacketsSent = inputMetrics.inputPacketsSent
        snapshot.averageInputQueueLatencyMs = inputMetrics.averageInputQueueLatencyMs
        snapshot.maxInputQueueLatencyMs = inputMetrics.maxInputQueueLatencyMs
        snapshot.averageInputTransportLatencyMs = inputMetrics.averageInputTransportLatencyMs
        snapshot.maxInputTransportLatencyMs = inputMetrics.maxInputTransportLatencyMs
    }

    private func syncMediaPipelineMetrics() async {
        let pipelineStats = await mediaPipeline.snapshot()
        snapshot.decodedVideoFrames = pipelineStats.decodedVideoFrames
        snapshot.renderedVideoFrames = pipelineStats.renderedVideoFrames
        snapshot.decodedAudioBuffers = pipelineStats.decodedAudioBuffers
        snapshot.playedAudioBuffers = pipelineStats.playedAudioBuffers
        snapshot.averageVideoDecodeLatencyMs = pipelineStats.averageVideoDecodeLatencyMs
        snapshot.maxVideoDecodeLatencyMs = pipelineStats.maxVideoDecodeLatencyMs
        snapshot.averageHostProcessingLatencyMs = pipelineStats.averageHostProcessingLatencyMs
        snapshot.maxHostProcessingLatencyMs = pipelineStats.maxHostProcessingLatencyMs
        snapshot.averageAudioDecodeLatencyMs = pipelineStats.averageAudioDecodeLatencyMs
        snapshot.maxAudioDecodeLatencyMs = pipelineStats.maxAudioDecodeLatencyMs
        snapshot.audioUnderrunEvents = pipelineStats.audioUnderrunEvents
        metricsContinuation.yield(snapshot)
    }

    public func stop() async {
        if lifecycle.state == .stopped {
            return
        }

        try? await flushPendingInputIfPossible()
        await syncInputSenderMetrics()

        try? lifecycle.transition(to: .stopping)
        eventContinuation.yield(.stateChanged(.stopping))

        try? lifecycle.transition(to: .stopped)
        eventContinuation.yield(.stateChanged(.stopped))
        metricsContinuation.yield(snapshot)
        metricsForwardingTask?.cancel()
        metricsForwardingTask = nil
        metricsContinuation.finish()
        eventContinuation.finish()
        Task {
            await self.primedSockets?.close()
            await mediaPipeline.teardown()
        }
    }
}
