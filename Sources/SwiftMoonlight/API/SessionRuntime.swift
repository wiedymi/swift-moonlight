import Foundation

public struct StreamRuntimeConfiguration: Sendable, Equatable {
    public var controlEncryption: ControlEncryptionContext?
    public var stopOnControlTermination: Bool
    public var maxReconnectAttempts: Int
    public var reconnectBackoff: Duration
    public var inputSenderConfiguration: InputSenderConfiguration
    public var videoPipelineSubmissionMode: VideoPipelineSubmissionMode
    public var videoPacketTraceLimit: Int

    public init(
        controlEncryption: ControlEncryptionContext? = nil,
        stopOnControlTermination: Bool = true,
        maxReconnectAttempts: Int = 0,
        reconnectBackoff: Duration = .milliseconds(100),
        inputSenderConfiguration: InputSenderConfiguration = .init(),
        videoPipelineSubmissionMode: VideoPipelineSubmissionMode = .asynchronous(maxInFlightFrames: 4),
        videoPacketTraceLimit: Int = 0
    ) {
        self.controlEncryption = controlEncryption
        self.stopOnControlTermination = stopOnControlTermination
        self.maxReconnectAttempts = maxReconnectAttempts
        self.reconnectBackoff = reconnectBackoff
        self.inputSenderConfiguration = inputSenderConfiguration
        self.videoPipelineSubmissionMode = videoPipelineSubmissionMode
        self.videoPacketTraceLimit = max(0, videoPacketTraceLimit)
    }
}

public struct RuntimeObservationSnapshot: Sendable, Equatable {
    public var controlMessagesObserved: Int
    public var controlRoundTripTimeMs: Int?
    public var controlRoundTripTimeVarianceMs: Int?
    public var controlPacketLossRatio: Double?
    public var controlPacketLossVarianceRatio: Double?
    public var controlQueuedSendBytes: Int?
    public var controlInFlightSendBytes: Int?
    public var controlDiscardedSocketDatagrams: UInt64?
    public var videoPacketsObserved: Int
    public var audioPacketsObserved: Int
    public var audioConcealmentPackets: Int
    public var missingVideoPackets: Int
    public var missingAudioPackets: Int
    public var reorderedVideoPackets: Int
    public var reorderedAudioPackets: Int
    public var videoDiscontinuityEvents: Int
    public var videoFrameFECStatusReports: Int
    public var recoverableVideoDecodeFailures: Int
    public var videoPacketTrace: [VideoPacketTraceEntry]
    public var reconnectAttempts: Int
    public var unexpectedDisconnect: Bool

    public init(
        controlMessagesObserved: Int = 0,
        controlRoundTripTimeMs: Int? = nil,
        controlRoundTripTimeVarianceMs: Int? = nil,
        controlPacketLossRatio: Double? = nil,
        controlPacketLossVarianceRatio: Double? = nil,
        controlQueuedSendBytes: Int? = nil,
        controlInFlightSendBytes: Int? = nil,
        controlDiscardedSocketDatagrams: UInt64? = nil,
        videoPacketsObserved: Int = 0,
        audioPacketsObserved: Int = 0,
        audioConcealmentPackets: Int = 0,
        missingVideoPackets: Int = 0,
        missingAudioPackets: Int = 0,
        reorderedVideoPackets: Int = 0,
        reorderedAudioPackets: Int = 0,
        videoDiscontinuityEvents: Int = 0,
        videoFrameFECStatusReports: Int = 0,
        recoverableVideoDecodeFailures: Int = 0,
        videoPacketTrace: [VideoPacketTraceEntry] = [],
        reconnectAttempts: Int = 0,
        unexpectedDisconnect: Bool = false
    ) {
        self.controlMessagesObserved = controlMessagesObserved
        self.controlRoundTripTimeMs = controlRoundTripTimeMs
        self.controlRoundTripTimeVarianceMs = controlRoundTripTimeVarianceMs
        self.controlPacketLossRatio = controlPacketLossRatio
        self.controlPacketLossVarianceRatio = controlPacketLossVarianceRatio
        self.controlQueuedSendBytes = controlQueuedSendBytes
        self.controlInFlightSendBytes = controlInFlightSendBytes
        self.controlDiscardedSocketDatagrams = controlDiscardedSocketDatagrams
        self.videoPacketsObserved = videoPacketsObserved
        self.audioPacketsObserved = audioPacketsObserved
        self.audioConcealmentPackets = audioConcealmentPackets
        self.missingVideoPackets = missingVideoPackets
        self.missingAudioPackets = missingAudioPackets
        self.reorderedVideoPackets = reorderedVideoPackets
        self.reorderedAudioPackets = reorderedAudioPackets
        self.videoDiscontinuityEvents = videoDiscontinuityEvents
        self.videoFrameFECStatusReports = videoFrameFECStatusReports
        self.recoverableVideoDecodeFailures = recoverableVideoDecodeFailures
        self.videoPacketTrace = videoPacketTrace
        self.reconnectAttempts = reconnectAttempts
        self.unexpectedDisconnect = unexpectedDisconnect
    }
}

public actor SessionRuntime {
    private let session: MoonlightSession
    private let controlService: ControlChannelService?
    private let videoService: VideoIngestService?
    private let audioService: AudioIngestService?
    private let configuration: StreamRuntimeConfiguration
    private var observation = RuntimeObservationSnapshot()

    private var controlTask: Task<Void, Never>?
    private var videoTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var recoveryMonitorTask: Task<Void, Never>?
    private var controlMetricsTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?
    private var pendingFECStatuses: [VideoFrameFECStatus] = []
    private enum KeyframeReason {
        case startup, discontinuity, decodeFailure, decoderPriming
        var warning: String? {
            switch self {
            case .startup: nil
            case .discontinuity: "Video discontinuity detected; requested a new keyframe"
            case .decodeFailure: "Video decoder rejected bad frame data; requested a new keyframe"
            case .decoderPriming: "Video decoder has not produced frames yet; requested a new keyframe"
            }
        }
    }
    private var pendingKeyframe: KeyframeReason?
    private var requestedStartupIDR = false
    private var requestedDecoderPrimingIDR = false
    private var lastIDRRequestTime: ContinuousClock.Instant?
    private static let idrRequestCooldown: Duration = .seconds(1)
    private static let mediaMetricsPublishInterval: TimeInterval = 0.1

    public init(
        session: MoonlightSession,
        controlService: ControlChannelService? = nil,
        videoService: VideoIngestService? = nil,
        audioService: AudioIngestService? = nil,
        configuration: StreamRuntimeConfiguration = .init()
    ) {
        self.session = session
        self.controlService = controlService
        self.videoService = videoService
        self.audioService = audioService
        self.configuration = configuration
    }

    public func start() {
        guard !Task.isCancelled, controlTask == nil, videoTask == nil, audioTask == nil, feedbackTask == nil else { return }
        if let controlService {
            controlTask = Task {
                await runControlLoop(service: controlService)
            }
            controlMetricsTask = Task { await runControlMetricsLoop(service: controlService) }
        }

        if let videoService {
            videoTask = Task {
                await runVideoLoop(service: videoService)
            }
            if controlService != nil {
                recoveryMonitorTask = Task { await runRecoveryMonitor(service: videoService) }
            }
        }

        if let audioService {
            audioTask = Task {
                await runAudioLoop(service: audioService)
            }
        }
    }

    public func stop() async {
        recoveryMonitorTask?.cancel()
        recoveryMonitorTask = nil
        controlMetricsTask?.cancel()
        controlMetricsTask = nil
        controlTask?.cancel()
        videoTask?.cancel()
        audioTask?.cancel()
        feedbackTask?.cancel()
        pendingFECStatuses.removeAll()
        pendingKeyframe = nil
        controlTask = nil
        videoTask = nil
        audioTask = nil
        await session.stop()
    }

    public func snapshot() async -> RuntimeObservationSnapshot {
        if let controlService {
            await refreshControlTransportMetrics(from: controlService)
        }
        var snapshot = observation
        if let videoService {
            let videoSnapshot = await videoService.snapshot()
            snapshot.videoPacketsObserved = videoSnapshot.observedPacketCount
            snapshot.missingVideoPackets = videoSnapshot.missingPacketCount
            snapshot.reorderedVideoPackets = videoSnapshot.reorderedPacketCount
            snapshot.videoDiscontinuityEvents = videoSnapshot.discontinuityCount
            snapshot.recoverableVideoDecodeFailures = videoSnapshot.recoverableDecodeFailureCount
            snapshot.videoPacketTrace = videoSnapshot.packetTrace
        }
        if let audioService {
            snapshot.audioPacketsObserved = await audioService.snapshotObservedPacketCount()
            snapshot.audioConcealmentPackets = await audioService.snapshotConcealedPacketCount()
            snapshot.missingAudioPackets = await audioService.snapshotMissingPacketCount()
            snapshot.reorderedAudioPackets = await audioService.snapshotReorderedPacketCount()
        }
        return snapshot
    }

    private func runControlLoop(service: ControlChannelService) async {
        while !Task.isCancelled {
            do {
                let message: ControlMessage?
                if let controlEncryption = configuration.controlEncryption {
                    message = try await service.receiveNextEncryptedMessage(encryption: controlEncryption)
                } else {
                    message = try await service.receiveNextMessage()
                }

                guard let message else {
                    break
                }

                observation.controlMessagesObserved += 1
                await refreshControlTransportMetrics(from: service)
                await session.updateRuntimeMetrics(
                    controlRoundTripTimeMs: observation.controlRoundTripTimeMs,
                    controlRoundTripTimeVarianceMs: observation.controlRoundTripTimeVarianceMs,
                    controlPacketLossRatio: observation.controlPacketLossRatio,
                    controlPacketLossVarianceRatio: observation.controlPacketLossVarianceRatio,
                    controlMessagesObserved: observation.controlMessagesObserved
                )
                await handle(controlMessage: message)
            } catch {
                let recovered = await handleRuntimeError(error)
                if !recovered {
                    return
                }
            }
        }
    }

    private func runControlMetricsLoop(service: ControlChannelService) async {
        while !Task.isCancelled {
            await refreshControlTransportMetrics(from: service)
            guard !Task.isCancelled else { return }
            await session.updateRuntimeMetrics(
                controlRoundTripTimeMs: observation.controlRoundTripTimeMs,
                controlRoundTripTimeVarianceMs: observation.controlRoundTripTimeVarianceMs,
                controlPacketLossRatio: observation.controlPacketLossRatio,
                controlPacketLossVarianceRatio: observation.controlPacketLossVarianceRatio
            )
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return }
        }
    }

    private func runRecoveryMonitor(service: VideoIngestService) async {
        while !Task.isCancelled {
            let snapshot = await service.snapshot()
            guard !Task.isCancelled else { return }
            await observeVideoRecovery(snapshot, service: service)
            if snapshot.observedPacketCount >= 120 && !requestedDecoderPrimingIDR {
                let stats = await session.mediaPipelineHandle().snapshot()
                if stats.decodedVideoFrames == 0 && !Task.isCancelled {
                    requestedDecoderPrimingIDR = queueKeyframe(.decoderPriming)
                }
            }
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return }
        }
    }

    private func observeVideoRecovery(_ snapshot: VideoIngestSnapshot, service: VideoIngestService) async {
        guard !Task.isCancelled else { return }
        let lostFrame = snapshot.discontinuityCount > observation.videoDiscontinuityEvents
        let badDecode = snapshot.recoverableDecodeFailureCount > observation.recoverableVideoDecodeFailures
        // Update before suspension so the frame loop and monitor cannot report
        // the same event twice. Older snapshots cannot reduce these counters.
        if snapshot.observedPacketCount >= observation.videoPacketsObserved {
            observation.videoPacketsObserved = snapshot.observedPacketCount
            observation.videoPacketTrace = snapshot.packetTrace
        }
        observation.missingVideoPackets = max(observation.missingVideoPackets, snapshot.missingPacketCount)
        observation.reorderedVideoPackets = max(observation.reorderedVideoPackets, snapshot.reorderedPacketCount)
        observation.videoDiscontinuityEvents = max(observation.videoDiscontinuityEvents, snapshot.discontinuityCount)
        observation.recoverableVideoDecodeFailures = max(observation.recoverableVideoDecodeFailures, snapshot.recoverableDecodeFailureCount)
        if lostFrame {
            queueKeyframe(.discontinuity)
            if controlService != nil {
                let statuses = await service.drainPendingFrameFECStatuses()
                guard !Task.isCancelled else { return }
                pendingFECStatuses.append(contentsOf: statuses)
                if pendingFECStatuses.count > 16 { pendingFECStatuses.removeFirst(pendingFECStatuses.count - 16) }
                startFeedbackIfNeeded()
            }
        }
        if badDecode { queueKeyframe(.decodeFailure) }
    }

    private func runVideoLoop(service: VideoIngestService) async {
        var lastMetricsPublishTime: Date?
        while !Task.isCancelled {
            do {
                let frame = try await service.receiveNextFrame()
                let videoSnapshot = await service.snapshot()
                let observedCount = videoSnapshot.observedPacketCount
                let missingCount = videoSnapshot.missingPacketCount
                let reorderedCount = videoSnapshot.reorderedPacketCount
                let discontinuityCount = videoSnapshot.discontinuityCount
                let recoverableDecodeFailureCount = videoSnapshot.recoverableDecodeFailureCount
                let now = Date()
                let shouldPublishMetrics = frame == nil || lastMetricsPublishTime.map {
                    now.timeIntervalSince($0) >= Self.mediaMetricsPublishInterval
                } ?? true
                await observeVideoRecovery(videoSnapshot, service: service)

                if shouldPublishMetrics {
                    lastMetricsPublishTime = now
                    let pipelineStats = await session.mediaPipelineHandle().snapshot()
                    await session.updateRuntimeMetrics(
                        controlRoundTripTimeMs: observation.controlRoundTripTimeMs,
                        controlRoundTripTimeVarianceMs: observation.controlRoundTripTimeVarianceMs,
                        controlPacketLossRatio: observation.controlPacketLossRatio,
                        controlPacketLossVarianceRatio: observation.controlPacketLossVarianceRatio,
                        videoPacketsObserved: observedCount,
                        missingVideoPackets: missingCount,
                        reorderedVideoPackets: reorderedCount,
                        videoDiscontinuityEvents: discontinuityCount,
                        videoFrameFECStatusReports: observation.videoFrameFECStatusReports,
                        recoverableVideoDecodeFailures: recoverableDecodeFailureCount,
                        decodedVideoFrames: pipelineStats.decodedVideoFrames,
                        renderedVideoFrames: pipelineStats.renderedVideoFrames,
                        averageVideoDecodeLatencyMs: pipelineStats.averageVideoDecodeLatencyMs,
                        maxVideoDecodeLatencyMs: pipelineStats.maxVideoDecodeLatencyMs,
                        averageVideoQueueLatencyMs: pipelineStats.averageVideoQueueLatencyMs,
                        maxVideoQueueLatencyMs: pipelineStats.maxVideoQueueLatencyMs,
                        averageVideoRenderSubmissionLatencyMs: pipelineStats.averageVideoRenderSubmissionLatencyMs,
                        maxVideoRenderSubmissionLatencyMs: pipelineStats.maxVideoRenderSubmissionLatencyMs,
                        averageHostProcessingLatencyMs: pipelineStats.averageHostProcessingLatencyMs,
                        maxHostProcessingLatencyMs: pipelineStats.maxHostProcessingLatencyMs
                    )
                    if pipelineStats.decodedVideoFrames == 0,
                       observedCount >= 120,
                       !requestedDecoderPrimingIDR
                    {
                        requestedDecoderPrimingIDR = queueKeyframe(.decoderPriming)
                    }
                }
                if frame == nil {
                    break
                }
            } catch {
                let recovered = await handleRuntimeError(error)
                if !recovered {
                    return
                }
            }
        }
    }

    private func runAudioLoop(service: AudioIngestService) async {
        var lastMetricsPublishTime: Date?
        while !Task.isCancelled {
            do {
                let packet = try await service.receiveNextPacket()
                let now = Date()
                let shouldPublishMetrics = packet == nil || lastMetricsPublishTime.map {
                    now.timeIntervalSince($0) >= Self.mediaMetricsPublishInterval
                } ?? true
                if shouldPublishMetrics {
                    lastMetricsPublishTime = now
                    let observedCount = await service.snapshotObservedPacketCount()
                    let concealmentCount = await service.snapshotConcealedPacketCount()
                    let missingCount = await service.snapshotMissingPacketCount()
                    let reorderedCount = await service.snapshotReorderedPacketCount()
                    let pipelineStats = await session.mediaPipelineHandle().snapshot()
                    observation.audioPacketsObserved = observedCount
                    observation.audioConcealmentPackets = concealmentCount
                    observation.missingAudioPackets = missingCount
                    observation.reorderedAudioPackets = reorderedCount
                    await session.updateRuntimeMetrics(
                        controlRoundTripTimeMs: observation.controlRoundTripTimeMs,
                        controlRoundTripTimeVarianceMs: observation.controlRoundTripTimeVarianceMs,
                        controlPacketLossRatio: observation.controlPacketLossRatio,
                        controlPacketLossVarianceRatio: observation.controlPacketLossVarianceRatio,
                        audioPacketsObserved: observedCount,
                        audioConcealmentPackets: concealmentCount,
                        missingAudioPackets: missingCount,
                        reorderedAudioPackets: reorderedCount,
                        decodedAudioBuffers: pipelineStats.decodedAudioBuffers,
                        playedAudioBuffers: pipelineStats.playedAudioBuffers,
                        averageAudioDecodeLatencyMs: pipelineStats.averageAudioDecodeLatencyMs,
                        maxAudioDecodeLatencyMs: pipelineStats.maxAudioDecodeLatencyMs,
                        audioUnderrunEvents: pipelineStats.audioUnderrunEvents
                    )
                }
                if packet == nil {
                    break
                }
            } catch {
                let recovered = await handleRuntimeError(error)
                if !recovered {
                    return
                }
            }
        }
    }

    private func handleRuntimeError(_ error: Error) async -> Bool {
        if error is CancellationError || Task.isCancelled {
            return false
        }

        let moonlightError: MoonlightError
        if let typed = error as? MoonlightError {
            moonlightError = typed
        } else {
            moonlightError = MoonlightError(.unsupportedOperation, message: String(describing: error))
        }

        if observation.reconnectAttempts < configuration.maxReconnectAttempts {
            observation.reconnectAttempts += 1
            await session.updateRuntimeMetrics(reconnectAttempts: observation.reconnectAttempts)
            await session.warn(.init("Transient runtime failure; attempting reconnect \(observation.reconnectAttempts) of \(configuration.maxReconnectAttempts)"))
            do {
                try await Task.sleep(for: configuration.reconnectBackoff)
            } catch {
                return false
            }
            return true
        }

        observation.unexpectedDisconnect = true
        await session.updateRuntimeMetrics(
            reconnectAttempts: observation.reconnectAttempts,
            unexpectedDisconnect: true
        )
        await session.fail(moonlightError)
        return false
    }

    private func refreshControlTransportMetrics(from service: ControlChannelService) async {
        guard let metrics = await service.snapshotTransportMetrics(), metrics.isConnected else {
            return
        }

        observation.controlRoundTripTimeMs = metrics.roundTripTimeMs
        observation.controlRoundTripTimeVarianceMs = metrics.roundTripTimeVarianceMs
        observation.controlPacketLossRatio = metrics.packetLossRatio
        observation.controlPacketLossVarianceRatio = metrics.packetLossVarianceRatio
        observation.controlQueuedSendBytes = metrics.queuedSendBytes
        observation.controlInFlightSendBytes = metrics.inFlightSendBytes
        observation.controlDiscardedSocketDatagrams = metrics.discardedSocketDatagrams
    }

    private func handle(controlMessage: ControlMessage) async {
        if videoService != nil, !requestedStartupIDR {
            requestedStartupIDR = true
            queueKeyframe(.startup)
        }

        switch controlMessage {
        case .rumble(let rumble):
            await session.receive(controllerFeedback: .init(
                controllerID: Int(rumble.controllerNumber),
                effect: .rumble(
                    lowFrequencyMotor: rumble.lowFrequencyMotor,
                    highFrequencyMotor: rumble.highFrequencyMotor
                )
            ))

        case .rumbleTriggers(let triggers):
            await session.receive(controllerFeedback: .init(
                controllerID: Int(triggers.controllerNumber),
                effect: .triggerRumble(
                    leftTriggerMotor: triggers.leftTriggerMotor,
                    rightTriggerMotor: triggers.rightTriggerMotor
                )
            ))

        case .setMotionEventState(let motion):
            await session.receive(controllerFeedback: .init(
                controllerID: Int(motion.controllerNumber),
                effect: .motionReport(
                    motionType: motion.motionType,
                    reportRateHz: motion.reportRateHz
                )
            ))

        case .setControllerLED(let led):
            await session.receive(controllerFeedback: .init(
                controllerID: Int(led.controllerNumber),
                effect: .led(
                    red: led.red,
                    green: led.green,
                    blue: led.blue
                )
            ))

        case .hdrModeChanged(let hdr):
            await session.receive(hdrMode: hdr)
            await session.warn(.init("HDR mode changed: \(hdr.enabled ? "enabled" : "disabled")"))

        case .adaptiveTriggers(let adaptive):
            await session.receive(controllerFeedback: .init(
                controllerID: Int(adaptive.controllerNumber),
                effect: .adaptiveTriggers(
                    eventFlags: adaptive.eventFlags,
                    leftTriggerType: adaptive.leftTriggerType,
                    rightTriggerType: adaptive.rightTriggerType,
                    leftPayload: adaptive.leftPayload,
                    rightPayload: adaptive.rightPayload
                )
            ))

        case .terminated(let termination):
            await session.fail(MoonlightError(.unsupportedOperation, message: "Stream terminated with host code \(termination.rawCode)"))
            if configuration.stopOnControlTermination {
                await session.stop()
            }
        }
    }

    @discardableResult
    private func queueKeyframe(_ reason: KeyframeReason) -> Bool {
        guard controlService != nil, !Task.isCancelled else { return false }
        let now = ContinuousClock().now
        guard lastIDRRequestTime.map({ $0.duration(to: now) >= Self.idrRequestCooldown }) ?? true else { return false }
        lastIDRRequestTime = now
        pendingKeyframe = reason
        startFeedbackIfNeeded()
        return true
    }

    private func startFeedbackIfNeeded() {
        guard feedbackTask == nil, !Task.isCancelled else { return }
        feedbackTask = Task { await runFeedbackLoop() }
    }

    private func runFeedbackLoop() async {
        defer { feedbackTask = nil }
        guard let controlService else { return }
        while !Task.isCancelled {
            // Keyframe recovery takes precedence over advisory loss reports.
            if let reason = pendingKeyframe {
                pendingKeyframe = nil
                await requestIDRFrame(warningMessage: reason.warning)
            } else if !pendingFECStatuses.isEmpty {
                let status = pendingFECStatuses.removeFirst()
                do {
                    try await controlService.sendFrameFECStatus(status, encryption: configuration.controlEncryption)
                    if !Task.isCancelled { observation.videoFrameFECStatusReports += 1 }
                } catch {
                    if !Task.isCancelled { await session.warn(.init("Video discontinuity detected; failed to send FEC status")) }
                }
            } else { return }
        }
    }

    private func requestIDRFrame(warningMessage: String?) async {
        guard let controlService else { return }

        do {
            // Clear stale sequence state before the host can send its keyframe.
            await videoService?.flushForKeyframeRequest()
            try Task.checkCancellation()
            try await controlService.requestIDRFrame(encryption: configuration.controlEncryption)
            try Task.checkCancellation()
            if let warningMessage {
                await session.warn(.init(warningMessage))
            }
        } catch {
            guard !Task.isCancelled else { return }
            let errorDetail = (error as? MoonlightError)?.message ?? error.localizedDescription
            if let warningMessage {
                await session.warn(.init("\(warningMessage.replacingOccurrences(of: "requested", with: "failed to request")): \(errorDetail)"))
            } else {
                await session.warn(.init("Failed to request an initial keyframe: \(errorDetail)"))
            }
        }
    }
}
