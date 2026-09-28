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
    private var requestedStartupIDR = false
    private var requestedDecoderPrimingIDR = false
    private var lastIDRRequestTime: Date?
    private static let idrRequestCooldown: TimeInterval = 1.0
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
        if let controlService {
            controlTask = Task {
                await runControlLoop(service: controlService)
            }
        }

        if let videoService {
            videoTask = Task {
                await runVideoLoop(service: videoService)
            }
        }

        if let audioService {
            audioTask = Task {
                await runAudioLoop(service: audioService)
            }
        }
    }

    public func stop() async {
        controlTask?.cancel()
        videoTask?.cancel()
        audioTask?.cancel()
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
                if discontinuityCount > observation.videoDiscontinuityEvents {
                    if let controlService {
                        let fecStatuses = await service.drainPendingFrameFECStatuses()
                        for status in fecStatuses {
                            do {
                                try await controlService.sendFrameFECStatus(
                                    status,
                                    encryption: configuration.controlEncryption
                                )
                                observation.videoFrameFECStatusReports += 1
                            } catch {
                                await session.warn(.init("Video discontinuity detected; failed to send FEC status"))
                                break
                            }
                        }
                    }
                    await requestIDRFrameIfNeeded(warningMessage: "Video discontinuity detected; requested a new keyframe")
                }
                if recoverableDecodeFailureCount > observation.recoverableVideoDecodeFailures {
                    await requestIDRFrameIfNeeded(warningMessage: "Video decoder rejected bad frame data; requested a new keyframe")
                }
                observation.videoPacketsObserved = observedCount
                observation.missingVideoPackets = missingCount
                observation.reorderedVideoPackets = reorderedCount
                observation.videoDiscontinuityEvents = discontinuityCount
                observation.recoverableVideoDecodeFailures = recoverableDecodeFailureCount
                observation.videoPacketTrace = videoSnapshot.packetTrace

                if shouldPublishMetrics {
                    lastMetricsPublishTime = now
                    let pipelineStats = await session.mediaPipelineHandle().snapshot()
                    if let controlService {
                        await refreshControlTransportMetrics(from: controlService)
                    }
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
                        requestedDecoderPrimingIDR = true
                        await requestIDRFrame(warningMessage: "Video decoder has not produced frames yet; requested a new keyframe")
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
                    if let controlService {
                        await refreshControlTransportMetrics(from: controlService)
                    }
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
    }

    private func handle(controlMessage: ControlMessage) async {
        if videoService != nil, !requestedStartupIDR {
            requestedStartupIDR = true
            await requestIDRFrame(warningMessage: nil)
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

    private func requestIDRFrameIfNeeded(warningMessage: String) async {
        let now = Date()
        let shouldRequest = lastIDRRequestTime.map { now.timeIntervalSince($0) >= Self.idrRequestCooldown } ?? true
        guard shouldRequest else {
            return
        }

        lastIDRRequestTime = now
        await requestIDRFrame(warningMessage: warningMessage)
    }

    private func requestIDRFrame(warningMessage: String?) async {
        guard let controlService else { return }

        do {
            try await controlService.requestIDRFrame(encryption: configuration.controlEncryption)
            // Flush the depacketizer so stale sequence state doesn't cause us to
            // miss the incoming keyframe. The IDR will be the next frame from the
            // encoder, and we need to capture it from its very first packet.
            await videoService?.flushForKeyframeRequest()
            if let warningMessage {
                await session.warn(.init(warningMessage))
            }
        } catch {
            let errorDetail = (error as? MoonlightError)?.message ?? error.localizedDescription
            if let warningMessage {
                await session.warn(.init("\(warningMessage.replacingOccurrences(of: "requested", with: "failed to request")): \(errorDetail)"))
            } else {
                await session.warn(.init("Failed to request an initial keyframe: \(errorDetail)"))
            }
        }
    }
}
