import Foundation

public actor IntegrationHarness {
    private let client: MoonlightClient
    private let configuration: IntegrationHarnessConfiguration
    private let traceEnabled: Bool

    public init(client: MoonlightClient, configuration: IntegrationHarnessConfiguration, traceEnabled: Bool = false) {
        self.client = client
        self.configuration = configuration
        self.traceEnabled = traceEnabled
    }

    public static func production(
        storageDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logger: any MoonlightLogger = DefaultLogger(),
        metricsSink: any MetricsSink = NoopMetricsSink(),
        enableDiscovery: Bool = true,
        httpClient: (any HTTPClient)? = nil
    ) throws -> IntegrationHarness {
        let clientConfiguration = try ProductionClientFactory.configuration(
            storageDirectory: storageDirectory,
            logger: logger,
            metricsSink: metricsSink,
            enableDiscovery: enableDiscovery,
            httpClient: httpClient
        )
        return IntegrationHarness(
            client: MoonlightClient(configuration: clientConfiguration),
            configuration: try IntegrationHarnessConfiguration.fromEnvironment(environment),
            traceEnabled: environment["SWIFT_MOONLIGHT_SMOKE_TRACE"] == "1"
        )
    }

    public func runSmokeTest() async throws -> SmokeTestReport {
        trace("adding host \(configuration.endpoint.address):\(configuration.endpoint.port)")
        let knownHosts = try await client.discoverHosts()
        let host = try await selectHost(from: knownHosts)
        trace("refreshing host \(host.id.rawValue)")
        let refreshed = try await client.refreshHost(host.id)
        trace("refreshed host paired=\(refreshed.pairingState.isPaired)")

        let paired: Bool
        if refreshed.pairingState.isPaired {
            paired = true
        } else {
            trace("pairing host")
            let auth = try await configuration.pairingAuthProvider()
            let pairingResult = try await client.pair(hostID: host.id, auth: auth)
            paired = pairingResult.state.isPaired
            trace("pair result paired=\(paired)")
        }

        trace("fetching apps")
        let apps = try await client.fetchApps(hostID: host.id)
        let appsFetched = !apps.isEmpty
        let selectedAppID = selectAppID(from: apps)
        trace("apps fetched count=\(apps.count) selected=\(selectedAppID)")

        var preLaunchCancelAttempted = false
        if configuration.cancelCurrentAppBeforeLaunch {
            trace("cancelling current host app before launch")
            try await client.cancelCurrentApp(hostID: host.id)
            preLaunchCancelAttempted = true
            trace("current host app cancel completed")
        }

        trace("opening session")
        let session = try await client.openSession(
            hostID: host.id,
            appID: selectedAppID,
            configuration: configuration.streamConfiguration
        )
        try await attachSmokePlaybackComponents(to: session)

        let preparedRuntime = try await client.prepareRuntime(
            for: session,
            hostID: host.id,
            configuration: configuration.runtimeConfiguration
        )
        let restartCount = configuration.restartStreamConfiguration == nil ? 0 : configuration.restartCount
        let shouldRestart = restartCount > 0
        let primaryObservation = await observeSession(
            session: session,
            preparedRuntime: preparedRuntime,
            shouldProbeInput: true,
            shouldStopAfterObservation: !shouldRestart,
            phase: "primary"
        )
        let negotiatedSession = await session.negotiatedSession
        let audioExpected = configuration.requireAudioPackets && negotiatedSession?.audioFormat != nil

        let restartAttempted = shouldRestart
        var restartLaunchAccepted = false
        var restartObservation: SmokeSessionObservation?
        var restartObservations: [SmokeRestartObservation] = []
        var activePreparedRuntime = preparedRuntime
        if let restartStreamConfiguration = configuration.restartStreamConfiguration, restartCount > 0 {
            for restartIndex in 1...restartCount {
                do {
                    trace(
                        "restarting session \(restartIndex)/\(restartCount) at " +
                        "\(Int(restartStreamConfiguration.resolution.width))x\(Int(restartStreamConfiguration.resolution.height))"
                    )
                    let restarted = try await client.restartSession(
                        hostID: host.id,
                        appID: selectedAppID,
                        configuration: restartStreamConfiguration,
                        previousRuntime: activePreparedRuntime,
                        options: SessionRestartOptions(runtimeConfiguration: configuration.runtimeConfiguration)
                    )
                    activePreparedRuntime = restarted.preparedRuntime
                    if restartIndex == 1 {
                        restartLaunchAccepted = true
                    }
                    try await attachSmokePlaybackComponents(to: restarted.session)
                    let observation = await observeSession(
                        session: restarted.session,
                        preparedRuntime: restarted.preparedRuntime,
                        shouldProbeInput: false,
                        shouldStopAfterObservation: restartIndex == restartCount,
                        phase: restartCount == 1 ? "restart" : "restart \(restartIndex)"
                    )
                    if restartIndex == 1 {
                        restartObservation = observation
                    }
                    restartObservations.append(SmokeRestartObservation(index: restartIndex, observation: observation))
                } catch {
                    trace("restart \(restartIndex) failed: \((error as? MoonlightError)?.message ?? error.localizedDescription)")
                    restartObservations.append(SmokeRestartObservation(index: restartIndex, launchAccepted: false))
                    await activePreparedRuntime.stop()
                    break
                }
            }
        }

        return SmokeTestReport(
            paired: paired,
            appsFetched: appsFetched,
            preLaunchCancelAttempted: preLaunchCancelAttempted,
            launchAccepted: true,
            controlConnected: primaryObservation.controlConnected,
            inputConnected: primaryObservation.inputConnected,
            controlRoundTripTimeMs: primaryObservation.controlRoundTripTimeMs,
            controlRoundTripTimeVarianceMs: primaryObservation.controlRoundTripTimeVarianceMs,
            controlPacketLossRatio: primaryObservation.controlPacketLossRatio,
            controlPacketLossVarianceRatio: primaryObservation.controlPacketLossVarianceRatio,
            videoPacketsObserved: primaryObservation.videoPacketsObserved,
            audioPacketsObserved: primaryObservation.audioPacketsObserved,
            missingVideoPackets: primaryObservation.missingVideoPackets,
            reorderedVideoPackets: primaryObservation.reorderedVideoPackets,
            videoDiscontinuityEvents: primaryObservation.videoDiscontinuityEvents,
            videoFrameFECStatusReports: primaryObservation.videoFrameFECStatusReports,
            decodedVideoFrames: primaryObservation.decodedVideoFrames,
            renderedVideoFrames: primaryObservation.renderedVideoFrames,
            inputPacketsSent: primaryObservation.inputPacketsSent,
            averageInputQueueLatencyMs: primaryObservation.averageInputQueueLatencyMs,
            maxInputQueueLatencyMs: primaryObservation.maxInputQueueLatencyMs,
            averageInputTransportLatencyMs: primaryObservation.averageInputTransportLatencyMs,
            maxInputTransportLatencyMs: primaryObservation.maxInputTransportLatencyMs,
            inputProbeSucceeded: primaryObservation.inputProbeSucceeded,
            inputProbeMode: configuration.inputProbeMode,
            inputProbeRepeatCount: configuration.inputProbeRepeatCount,
            maxInputLatencyMs: configuration.maxInputLatencyMs,
            maxMissingVideoPackets: configuration.maxMissingVideoPackets,
            maxVideoDiscontinuities: configuration.maxVideoDiscontinuities,
            videoPacketTrace: primaryObservation.videoPacketTrace,
            audioExpected: audioExpected,
            unexpectedDisconnect: primaryObservation.unexpectedDisconnect,
            restartAttempted: restartAttempted,
            restartLaunchAccepted: restartLaunchAccepted,
            restartControlConnected: restartObservation?.controlConnected ?? false,
            restartInputConnected: restartObservation?.inputConnected ?? false,
            restartVideoPacketsObserved: restartObservation?.videoPacketsObserved ?? 0,
            restartAudioPacketsObserved: restartObservation?.audioPacketsObserved ?? 0,
            restartDecodedVideoFrames: restartObservation?.decodedVideoFrames ?? 0,
            restartRenderedVideoFrames: restartObservation?.renderedVideoFrames ?? 0,
            restartUnexpectedDisconnect: restartObservation?.unexpectedDisconnect ?? false,
            restartCountRequested: restartCount,
            restartObservations: restartObservations
        )
    }

    private func attachSmokePlaybackComponents(to session: MoonlightSession) async throws {
        if let negotiated = await session.negotiatedSession {
            trace("negotiated channels \(negotiated.channels.map { "\($0.descriptor.kind):\($0.descriptor.port):\($0.descriptor.metadata)" }.joined(separator: ", "))")
            trace("encryption features \(negotiated.encryptionFeatures.rawValue) continuousAudio=\(configuration.streamConfiguration.requestContinuousAudio)")
        }
        try await session.attachVideoDecoder(DiscardingVideoDecoder())
        try await session.attachRenderer(NullRenderer())
        try await session.attachAudioDecoder(SilenceAudioDecoder())
        try await session.attachAudioSink(NullAudioSink())
    }

    private func observeSession(
        session: MoonlightSession,
        preparedRuntime: PreparedSessionRuntime,
        shouldProbeInput: Bool,
        shouldStopAfterObservation: Bool,
        phase: String
    ) async -> SmokeSessionObservation {
        if let videoSource = preparedRuntime.sockets.videoSource {
            if let port = try? await videoSource.localPort() {
                trace("\(phase) video socket local port \(port)")
            }
        }
        if let audioSource = preparedRuntime.sockets.audioSource {
            if let port = try? await audioSource.localPort() {
                trace("\(phase) audio socket local port \(port)")
            }
        }
        trace("starting \(phase) runtime")
        await preparedRuntime.runtime.start()

        let inputProbeSucceeded = shouldProbeInput
            ? await probeInputIfConnected(session: session, sockets: preparedRuntime.sockets)
            : true
        let inputMetrics = await session.currentMetricsSnapshot()
        trace("observing \(phase) for \(configuration.observationWindow)")
        try? await Task.sleep(for: configuration.observationWindow)

        let runtimeSnapshot = await preparedRuntime.runtime.snapshot()
        let controlRTTText = runtimeSnapshot.controlRoundTripTimeMs.map { String($0) } ?? "nil"
        let controlLossText = runtimeSnapshot.controlPacketLossRatio.map { String($0) } ?? "nil"
        trace(
            "\(phase) runtime snapshot videoPackets=\(runtimeSnapshot.videoPacketsObserved) " +
            "audioPackets=\(runtimeSnapshot.audioPacketsObserved) " +
            "controlRttMs=\(controlRTTText) " +
            "controlLossRatio=\(controlLossText) " +
            "missingVideo=\(runtimeSnapshot.missingVideoPackets) " +
            "reorderedVideo=\(runtimeSnapshot.reorderedVideoPackets) " +
            "videoDiscontinuities=\(runtimeSnapshot.videoDiscontinuityEvents) " +
            "fecStatusReports=\(runtimeSnapshot.videoFrameFECStatusReports)"
        )
        if shouldStopAfterObservation {
            trace("stopping \(phase) runtime")
            await preparedRuntime.stop()
            trace("\(phase) runtime stopped")
        }
        let pipelineStats = await session.mediaPipelineHandle().snapshot()
        trace("\(phase) pipeline snapshot decodedVideo=\(pipelineStats.decodedVideoFrames) renderedVideo=\(pipelineStats.renderedVideoFrames)")

        return SmokeSessionObservation(
            controlConnected: preparedRuntime.sockets.controlTransport != nil,
            inputConnected: preparedRuntime.sockets.inputTransport != nil,
            controlRoundTripTimeMs: runtimeSnapshot.controlRoundTripTimeMs,
            controlRoundTripTimeVarianceMs: runtimeSnapshot.controlRoundTripTimeVarianceMs,
            controlPacketLossRatio: runtimeSnapshot.controlPacketLossRatio,
            controlPacketLossVarianceRatio: runtimeSnapshot.controlPacketLossVarianceRatio,
            videoPacketsObserved: runtimeSnapshot.videoPacketsObserved,
            audioPacketsObserved: runtimeSnapshot.audioPacketsObserved,
            missingVideoPackets: runtimeSnapshot.missingVideoPackets,
            reorderedVideoPackets: runtimeSnapshot.reorderedVideoPackets,
            videoDiscontinuityEvents: runtimeSnapshot.videoDiscontinuityEvents,
            videoFrameFECStatusReports: runtimeSnapshot.videoFrameFECStatusReports,
            decodedVideoFrames: pipelineStats.decodedVideoFrames,
            renderedVideoFrames: pipelineStats.renderedVideoFrames,
            inputPacketsSent: inputMetrics.inputPacketsSent,
            averageInputQueueLatencyMs: inputMetrics.averageInputQueueLatencyMs,
            maxInputQueueLatencyMs: inputMetrics.maxInputQueueLatencyMs,
            averageInputTransportLatencyMs: inputMetrics.averageInputTransportLatencyMs,
            maxInputTransportLatencyMs: inputMetrics.maxInputTransportLatencyMs,
            inputProbeSucceeded: inputProbeSucceeded,
            videoPacketTrace: runtimeSnapshot.videoPacketTrace,
            unexpectedDisconnect: runtimeSnapshot.unexpectedDisconnect
        )
    }

    private func selectHost(from knownHosts: [MoonlightHost]) async throws -> MoonlightHost {
        let exactMatches = knownHosts.filter {
            $0.endpoint.address == configuration.endpoint.address &&
            $0.endpoint.port == configuration.endpoint.port
        }
        if let pairedExactMatch = exactMatches.first(where: \.pairingState.isPaired) {
            trace("reusing paired stored host \(pairedExactMatch.id.rawValue)")
            return pairedExactMatch
        }

        let pairedHosts = knownHosts.filter(\.pairingState.isPaired)
        if pairedHosts.count == 1 {
            trace("adopting override endpoint for paired host \(pairedHosts[0].id.rawValue)")
            return try await client.updateHostEndpoint(hostID: pairedHosts[0].id, endpoint: configuration.endpoint)
        }

        if let exactMatch = exactMatches.first {
            trace("reusing stored host \(exactMatch.id.rawValue)")
            return exactMatch
        }

        trace("stored host not found; adding host")
        return try await client.addHost(configuration.endpoint)
    }

    private func selectAppID(from apps: [RemoteApp]) -> RemoteApp.ID {
        let requested = configuration.appID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let app = apps.first(where: { $0.id == requested }) {
            return app.id
        }
        if let app = apps.first(where: { $0.name.caseInsensitiveCompare(requested) == .orderedSame }) {
            return app.id
        }
        if requested.caseInsensitiveCompare("desktop") == .orderedSame,
           let desktop = apps.first(where: {
               $0.id.caseInsensitiveCompare("desktop") == .orderedSame ||
               $0.name.caseInsensitiveCompare("desktop") == .orderedSame
           }) {
            return desktop.id
        }
        return configuration.appID
    }

    private func probeInputIfConnected(session: MoonlightSession, sockets: ChannelSocketSet) async -> Bool {
        guard sockets.inputTransport != nil else {
            return false
        }

        guard configuration.inputProbeMode != .disabled else {
            trace("input probe disabled")
            return true
        }

        do {
            for _ in 0..<configuration.inputProbeRepeatCount {
                switch configuration.inputProbeMode {
                case .disabled:
                    return true
                case .noop:
                    try await session.send(.mouse(.relativeMove(dx: 0, dy: 0)))
                    try await session.send(.mouse(.verticalScroll(delta: 0)))
                    try await session.flushPendingInput()
                case .reversibleRelativeMotion:
                    try await session.send(.mouse(.relativeMove(dx: 1, dy: 0)))
                    try await session.flushPendingInput()
                    try await session.send(.mouse(.relativeMove(dx: -1, dy: 0)))
                    try await session.flushPendingInput()
                case .absolutePointerSweep:
                    try await session.send(.mouse(.absoluteMove(x: 0.25, y: 0.5)))
                    try await session.flushPendingInput()
                    try await session.send(.mouse(.absoluteMove(x: 0.75, y: 0.5)))
                    try await session.flushPendingInput()
                    try await session.send(.mouse(.absoluteMove(x: 0.5, y: 0.5)))
                    try await session.flushPendingInput()
                }
            }
            trace("input probe sent \(configuration.inputProbeRepeatCount) \(configuration.inputProbeMode.rawValue) iteration(s)")
            return true
        } catch {
            let detail = (error as? MoonlightError)?.message ?? error.localizedDescription
            trace("input probe failed: \(detail)")
            return false
        }
    }

    private func trace(_ message: String) {
        guard traceEnabled else { return }
        fputs("[smoke] \(message)\n", stderr)
        fflush(stderr)
    }
}
