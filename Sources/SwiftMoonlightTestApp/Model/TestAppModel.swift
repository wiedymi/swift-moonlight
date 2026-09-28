#if os(macOS)
import AppKit
import Metal
import QuartzCore
import SwiftMoonlight
import SwiftUI
@MainActor
final class TestAppModel: ObservableObject {
    private struct PendingInputIngress: Sendable {
        var event: InputEvent
        var sender: any InputSending
        var sequence: UInt64
        var generation: UInt64
    }

    @Published var hosts: [MoonlightHost] = []
    @Published var selectedHostID: HostID?
    @Published var apps: [RemoteApp] = []
    @Published var selectedAppID: RemoteApp.ID?
    @Published var manualHostAddress = ""
    @Published var pin = ""
    @Published var passphrase = ""
    @Published var status = "Idle"
    @Published var latestMetrics = "No metrics yet"
    @Published var logLines: [String] = []
    @Published var surfaceHasFocus = false
    @Published var currentVideoDimensions: CGSize?
    @Published var mouseMode: TestAppMouseMode = .captured
    @Published var showLocalCursor = false
    @Published var streamSettings: TestAppStreamSettings = TestAppStreamSettingsStore.load() {
        didSet {
            TestAppStreamSettingsStore.save(streamSettings)
        }
    }

    let client: MoonlightClient?
    let hostStore: FileHostStore?
    let device: MTLDevice?

    private static let interactiveRuntimeConfiguration = StreamRuntimeConfiguration(
        inputSenderConfiguration: .init(mouseMotionDeliveryPolicy: .coalesced(interval: .milliseconds(1)))
    )

    private let autoStartConfiguration = AutoStartConfiguration.fromEnvironment()
    private var metalLayerReference: UnsafeSendableMetalLayerReference?
    private var session: MoonlightSession?
    private var preparedRuntime: PreparedSessionRuntime?
    private var eventTask: Task<Void, Never>?
    private var runtimeSnapshotTask: Task<Void, Never>?
    private var runtimeTask: Task<Void, Never>?
    private var resizeRestartTask: Task<Void, Never>?
    private var attemptedAutoStart = false
    private var inputGeneration: UInt64 = 0
    private var inputSequence: UInt64 = 0
    private var pendingInputIngress: [PendingInputIngress] = []
    private var inputIngressTask: Task<Void, Never>?
    private var resizeRestartGeneration: UInt64 = 0
    private var activeSessionHost: MoonlightHost?
    private var activeSessionAppID: RemoteApp.ID?
    private var activeLaunchResolution: CGSize?
    private lazy var inputDispatchQueue = InputEventDispatchQueue { [weak self] failure in
        await MainActor.run {
            self?.recordInputFailure("Input send failed: \(failure.message)")
        }
    }
    private let streamWindowManager = TestAppStreamWindowManager()
    private let settingsWindowManager = TestAppSettingsWindowManager()

    init(
        client: MoonlightClient?,
        hostStore: FileHostStore?,
        device: MTLDevice?,
        initializationError: Error? = nil
    ) {
        self.client = client
        self.hostStore = hostStore
        self.device = device
        appendLog("App launched")
        if let initializationError {
            status = "Initialization failed"
            appendLog("Initialization failed: \(initializationError.localizedDescription)")
        }
    }

    static func makeDefault() throws -> TestAppModel {
        let fileManager = FileManager.default
        let appSupportRoot = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let storageDirectory = appSupportRoot.appending(path: "swift-moonlight-test-app", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true)

        let hostStore = FileHostStore(fileURL: storageDirectory.appending(path: "hosts.json"))
        let identityStore = FileIdentityStore(
            fileURL: storageDirectory.appending(path: "identity.json"),
            defaultDisplayName: Host.current().localizedName ?? "swift-moonlight-test-app"
        )
        let pairingIdentityStore = FileRSAPairingIdentityStore(
            fileURL: storageDirectory.appending(path: "pairing-identity.json")
        )
        let configuration = ProductionClientFactory.configuration(
            hostStore: hostStore,
            identityStore: identityStore,
            pairingIdentityStore: pairingIdentityStore
        )
        return TestAppModel(
            client: MoonlightClient(configuration: configuration),
            hostStore: hostStore,
            device: MTLCreateSystemDefaultDevice()
        )
    }

    func attachLayer(_ layer: CAMetalLayer) {
        metalLayerReference = UnsafeSendableMetalLayerReference(layer: layer)
        if let device {
            layer.device = device
            layer.framebufferOnly = false
        }
    }

    func presentStreamWindow(fullscreen: Bool = false) {
        streamWindowManager.show(model: self, fullscreen: fullscreen)
    }

    func presentSettingsWindow() {
        settingsWindowManager.show(model: self)
    }

    func updateStreamSettings(_ update: (inout TestAppStreamSettings) -> Void) {
        var nextSettings = streamSettings
        update(&nextSettings)
        streamSettings = nextSettings.sanitized
    }

    func resetStreamSettings() {
        streamSettings = .default
    }

    func loadStoredHosts() {
        runOperation("Loading hosts") { [self] in
            guard let hostStore else { return }
            let storedHosts = try await hostStore.loadHosts()
            self.hosts = storedHosts
            if let selectedHostID, storedHosts.contains(where: { $0.id == selectedHostID }) {
                self.selectedHostID = selectedHostID
            } else {
                self.selectedHostID = storedHosts.first?.id
            }
            self.appendLog("Loaded \(storedHosts.count) stored host(s)")
            try await self.maybeAutoStart(using: storedHosts)
        }
    }

    func discoverHosts() {
        runOperation("Discovering hosts") { [self] in
            guard let client = self.client else { return }
            let discovered = try await client.discoverHosts()
            var refreshedHosts: [MoonlightHost] = []
            refreshedHosts.reserveCapacity(discovered.count)

            for host in discovered {
                do {
                    let refreshedHost = try await client.refreshHost(host)
                    refreshedHosts.append(refreshedHost)
                } catch {
                    refreshedHosts.append(host)
                    self.appendLog("Host refresh failed for \(host.endpoint.address):\(host.endpoint.port): \(error.localizedDescription)")
                }
            }

            self.hosts = refreshedHosts
            if self.selectedHostID == nil {
                self.selectedHostID = refreshedHosts.first?.id
            }
            self.appendLog("Discovered \(refreshedHosts.count) host(s)")
        }
    }

    func addManualHost() {
        runOperation("Adding host") { [self] in
            guard let client = self.client else { return }
            let endpoint = try self.parseManualEndpoint()
            let host = try await client.addHost(endpoint)
            self.hosts.append(host)
            self.selectedHostID = host.id
            self.manualHostAddress = ""
            self.appendLog("Added host \(host.endpoint.address):\(host.endpoint.port)")
        }
    }

    func refreshSelectedHost() {
        runOperation("Refreshing host") { [self] in
            guard let client = self.client else { return }
            let selectedHost = try self.requireSelectedHost()
            let refreshed = try await client.refreshHost(selectedHost)
            self.replaceHost(refreshed)
            self.selectedHostID = refreshed.id
            self.appendLog("Refreshed \(refreshed.name) as \(self.hostKindDescription(refreshed.kind))")
        }
    }

    func pairSelectedHost() {
        runOperation("Pairing host") { [self] in
            guard let client = self.client else { return }
            let selectedHost = try self.requireSelectedHost()
            await self.logStoredHosts(context: "Before pair")
            let pin = self.pin.isEmpty ? Self.generatePIN() : self.pin
            self.pin = pin
            self.appendLog("Pairing PIN: \(pin). Enter this PIN in the host confirmation prompt.")
            let auth: PairingAuth = self.passphrase.isEmpty ? .pin(pin) : .otp(pin: pin, passphrase: self.passphrase)
            let result = try await client.pair(host: selectedHost, auth: auth)
            self.appendLog("Pairing result: \(self.pairingStateDescription(result.state))")
            let refreshed = try await client.refreshHost(selectedHost)
            self.replaceHost(refreshed)
            self.selectedHostID = refreshed.id
        }
    }

    func fetchApps() {
        runOperation("Fetching apps") { [self] in
            guard let client = self.client else { return }
            let selectedHost = try self.requireSelectedHost()
            let fetchedApps = try await client.fetchApps(host: selectedHost)
            self.apps = fetchedApps
            self.selectedAppID = fetchedApps.first?.id
            self.appendLog("Fetched \(fetchedApps.count) app(s)")
        }
    }

    func unpairSelectedHost() {
        runOperation("Unpairing host") { [self] in
            guard let client = self.client else { return }
            let selectedHost = try self.requireSelectedHost()
            try await client.unpair(host: selectedHost)
            self.appendLog("Unpaired host")
            let refreshed = try await client.refreshHost(selectedHost)
            self.replaceHost(refreshed)
            self.selectedHostID = refreshed.id
        }
    }

    func startSelectedApp() {
        runOperation("Starting session") { [self] in
            guard let client = self.client,
                  let selectedAppID = self.selectedAppID
            else { return }
            let selectedHost = try self.requireSelectedHost()
            try await self.startSession(
                client: client,
                selectedHost: selectedHost,
                selectedAppID: selectedAppID
            )
        }
    }

    private func startSession(
        client: MoonlightClient,
        selectedHost: MoonlightHost,
        selectedAppID: RemoteApp.ID
    ) async throws {
        guard let device = self.device else {
            throw MoonlightError(.unsupportedOperation, message: "No Metal device available on this Mac")
        }
        self.presentStreamWindow(fullscreen: self.streamSettings.openFullscreenOnStart)
        let metalLayerReference = try await requireMetalLayerReference()
        let streamSurfaceSize = await resolvedStreamSurfaceSize(
            from: metalLayerReference.layer,
            waitForStableLayout: self.streamSettings.resolution == .streamWindow
        )

        await self.stopCurrentSession(closeStreamWindow: false)
        do {
            let streamConfiguration = self.streamSettings.streamConfiguration(surfaceSize: streamSurfaceSize)
            let session = try await client.openSession(
                host: selectedHost,
                appID: selectedAppID,
                configuration: streamConfiguration
            )

            // Prepare sockets before attaching heavy media components. The
            // runtime starts after attachments so decoded frames have a sink.
            let preparedRuntime = try await client.prepareRuntime(
                for: session,
                host: selectedHost,
                configuration: Self.interactiveRuntimeConfiguration
            )
            try await self.attachAndStartPreparedSession(
                session: session,
                preparedRuntime: preparedRuntime,
                selectedHost: selectedHost,
                selectedAppID: selectedAppID,
                streamConfiguration: streamConfiguration,
                device: device,
                metalLayerReference: metalLayerReference
            )
        } catch {
            self.streamWindowManager.close()
            try? await client.cancelCurrentApp(host: selectedHost)
            throw error
        }
    }

    private func requireMetalLayerReference() async throws -> UnsafeSendableMetalLayerReference {
        if let metalLayerReference {
            return metalLayerReference
        }

        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while clock.now < deadline {
            if let metalLayerReference {
                return metalLayerReference
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        throw MoonlightError(.unsupportedOperation, message: "Video surface is not ready")
    }

    private func resolvedStreamSurfaceSize(
        from layer: CAMetalLayer,
        waitForStableLayout: Bool
    ) async -> CGSize? {
        let attemptCount = waitForStableLayout ? 16 : 1
        let minimumStableAttempt = waitForStableLayout ? 8 : 0
        var previousSize: CGSize?

        for attempt in 0..<attemptCount {
            let size = currentStreamSurfaceSize(from: layer)
            if !waitForStableLayout {
                return size
            }

            if attempt >= minimumStableAttempt,
               let previousSize,
               let size,
               abs(previousSize.width - size.width) < 1,
               abs(previousSize.height - size.height) < 1
            {
                return size
            }

            previousSize = size
            try? await Task.sleep(for: .milliseconds(100))
        }

        return previousSize ?? currentStreamSurfaceSize(from: layer)
    }

    private func currentStreamSurfaceSize(from layer: CAMetalLayer) -> CGSize? {
        let drawableSize = layer.drawableSize
        if drawableSize.width > 1, drawableSize.height > 1 {
            return drawableSize
        }

        let scale = layer.contentsScale > 0 ? layer.contentsScale : 1
        let bounds = layer.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            return nil
        }

        return CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    func handleStreamSurfaceSizeChanged(_ surfaceSize: CGSize) {
        guard hasActiveSession,
              streamSettings.resolution == .streamWindow,
              activeSessionHost != nil,
              activeSessionAppID != nil
        else {
            return
        }

        let desiredResolution = streamSettings.streamConfiguration(surfaceSize: surfaceSize).resolution
        guard !Self.samePixelSize(desiredResolution, activeLaunchResolution) else {
            return
        }

        resizeRestartGeneration &+= 1
        let generation = resizeRestartGeneration
        resizeRestartTask?.cancel()
        resizeRestartTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(900))
            } catch {
                return
            }
            guard let self,
                  generation == self.resizeRestartGeneration
            else {
                return
            }
            await self.restartSessionForWindowResolution(surfaceSize)
        }
    }

    private func maybeAutoStart(using storedHosts: [MoonlightHost]) async throws {
        guard autoStartConfiguration.enabled,
              !attemptedAutoStart,
              let client
        else { return }

        attemptedAutoStart = true

        let selectedHost: MoonlightHost?
        if let hostOverride = autoStartConfiguration.hostOverride {
            if let matchingHost = storedHosts.first(where: {
                $0.endpoint.address == hostOverride.address && $0.endpoint.port == hostOverride.port
            }) {
                selectedHost = matchingHost
            } else {
                let pairedHosts = storedHosts.filter(\.pairingState.isPaired)
                if pairedHosts.count == 1 {
                    selectedHost = try await client.updateHostEndpoint(hostID: pairedHosts[0].id, endpoint: hostOverride)
                } else {
                    selectedHost = nil
                }
            }
        } else {
            selectedHost = storedHosts.first(where: \.pairingState.isPaired)
        }

        guard let selectedHost else {
            appendLog("Autostart skipped: no matching stored host")
            return
        }

        selectedHostID = selectedHost.id
        appendLog("Autostart selected host \(selectedHost.endpoint.address):\(selectedHost.endpoint.port)")

        let fetchedApps = try await client.fetchApps(host: selectedHost)
        apps = fetchedApps
        if let appIDOverride = autoStartConfiguration.appIDOverride,
           fetchedApps.contains(where: { $0.id == appIDOverride }) {
            selectedAppID = appIDOverride
        } else {
            selectedAppID = fetchedApps.first?.id
        }

        guard let selectedAppID else {
            appendLog("Autostart skipped: host returned no apps")
            return
        }

        appendLog("Autostart launching app \(selectedAppID)")
        try await startSession(
            client: client,
            selectedHost: selectedHost,
            selectedAppID: selectedAppID
        )
    }

    func stopSession() {
        Task { await stopCurrentSession() }
    }

    private func stopCurrentSession(closeStreamWindow: Bool = true, cancelPendingResizeRestart: Bool = true) async {
        if cancelPendingResizeRestart {
            resizeRestartTask?.cancel()
            resizeRestartTask = nil
            resizeRestartGeneration &+= 1
        }

        runtimeTask?.cancel()
        runtimeTask = nil

        eventTask?.cancel()
        eventTask = nil

        runtimeSnapshotTask?.cancel()
        runtimeSnapshotTask = nil

        if let preparedRuntime {
            await preparedRuntime.stop()
        }
        preparedRuntime = nil
        inputGeneration &+= 1
        inputSequence = 0
        clearPendingInputIngress()
        await inputDispatchQueue.clear(generation: inputGeneration)

        if let session {
            await session.stop()
        }
        session = nil
        activeSessionHost = nil
        activeSessionAppID = nil
        activeLaunchResolution = nil

        status = "Idle"
        latestMetrics = "No metrics yet"
        surfaceHasFocus = false
        currentVideoDimensions = nil
        if closeStreamWindow {
            streamWindowManager.close()
        }
        appendLog("Stopped session")
    }

    private func restartSessionForWindowResolution(_ surfaceSize: CGSize) async {
        resizeRestartTask = nil
        guard let client,
              let host = activeSessionHost,
              let appID = activeSessionAppID,
              let device = self.device,
              let metalLayerReference
        else {
            return
        }

        let streamConfiguration = streamSettings.streamConfiguration(surfaceSize: surfaceSize)
        let requestedResolution = streamConfiguration.resolution
        guard !Self.samePixelSize(requestedResolution, activeLaunchResolution) else {
            return
        }

        status = "Restarting for window size"
        appendLog("Restarting session for stream window resolution \(Int(requestedResolution.width))x\(Int(requestedResolution.height))")
        let previousRuntime = await detachCurrentSessionForRestart()
        do {
            let restarted = try await client.restartSession(
                host: host,
                appID: appID,
                configuration: streamConfiguration,
                previousRuntime: previousRuntime,
                options: .init(runtimeConfiguration: Self.interactiveRuntimeConfiguration)
            )
            try await attachAndStartPreparedSession(
                session: restarted.session,
                preparedRuntime: restarted.preparedRuntime,
                selectedHost: host,
                selectedAppID: appID,
                streamConfiguration: streamConfiguration,
                device: device,
                metalLayerReference: metalLayerReference
            )
        } catch let error as MoonlightError {
            status = "Error"
            appendLog("Resize restart failed: \(error.message)")
        } catch {
            status = "Error"
            appendLog("Resize restart failed: \(error.localizedDescription)")
        }
    }

    private func detachCurrentSessionForRestart() async -> PreparedSessionRuntime? {
        runtimeTask?.cancel()
        runtimeTask = nil

        eventTask?.cancel()
        eventTask = nil

        runtimeSnapshotTask?.cancel()
        runtimeSnapshotTask = nil

        let previousRuntime = preparedRuntime
        preparedRuntime = nil
        session = nil

        inputGeneration &+= 1
        inputSequence = 0
        clearPendingInputIngress()
        await inputDispatchQueue.clear(generation: inputGeneration)

        surfaceHasFocus = false
        currentVideoDimensions = nil
        latestMetrics = "Restarting"
        return previousRuntime
    }

    private func attachAndStartPreparedSession(
        session: MoonlightSession,
        preparedRuntime: PreparedSessionRuntime,
        selectedHost: MoonlightHost,
        selectedAppID: RemoteApp.ID,
        streamConfiguration: StreamConfiguration,
        device: MTLDevice,
        metalLayerReference: UnsafeSendableMetalLayerReference
    ) async throws {
        self.session = session
        self.preparedRuntime = preparedRuntime
        self.activeSessionHost = selectedHost
        self.activeSessionAppID = selectedAppID
        self.activeLaunchResolution = streamConfiguration.resolution

        self.bindSessionStreams(session)
        try await AppleMediaComponents.attachRecommendedPlaybackComponents(
            to: session,
            device: device,
            layer: metalLayerReference.layer,
            preferredDecodeMode: streamConfiguration.preferredDecodeMode,
            frameDiagnosticsHandler: { [weak self] diagnostics in
                self?.appendLog("Video pixel buffer: \(diagnostics.summary)")
            }
        )
        #if canImport(GameController)
        await session.attachControllerFeedbackSink(GameControllerFeedbackSink())
        #endif
        await self.logSocketPorts(preparedRuntime.sockets)
        self.startRuntimeSnapshotPolling(preparedRuntime.runtime)
        self.runtimeTask = Task {
            await preparedRuntime.runtime.start()
        }

        let hostName = selectedHost.name
        self.appendLog("Launch settings: \(self.streamSettings.summary)")
        self.appendLog("Launch resolution: \(Int(streamConfiguration.resolution.width))x\(Int(streamConfiguration.resolution.height))")
        self.appendLog("Started session for \(hostName) / \(selectedAppID)")
    }

    func selectHost(_ hostID: HostID) {
        guard selectedHostID != hostID else { return }
        selectedHostID = hostID
        apps = []
        selectedAppID = nil
    }

    func sendInput(_ event: InputEvent) {
        guard let session else { return }
        let generation = inputGeneration
        let sequence = inputSequence
        inputSequence &+= 1
        pendingInputIngress.append(PendingInputIngress(
            event: event,
            sender: session,
            sequence: sequence,
            generation: generation
        ))
        startInputIngressDrainIfNeeded()
    }

    private func startInputIngressDrainIfNeeded() {
        guard inputIngressTask == nil else { return }

        let inputDispatchQueue = inputDispatchQueue
        inputIngressTask = Task(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                guard let next = await MainActor.run(body: { self?.popNextInputIngress() }) else {
                    break
                }

                await inputDispatchQueue.enqueue(
                    next.event,
                    sender: next.sender,
                    sequence: next.sequence,
                    generation: next.generation
                )
            }

            await MainActor.run {
                guard let self else { return }
                self.inputIngressTask = nil
                if !self.pendingInputIngress.isEmpty {
                    self.startInputIngressDrainIfNeeded()
                }
            }
        }
    }

    private func popNextInputIngress() -> PendingInputIngress? {
        guard !pendingInputIngress.isEmpty else {
            return nil
        }
        return pendingInputIngress.removeFirst()
    }

    private func clearPendingInputIngress() {
        inputIngressTask?.cancel()
        inputIngressTask = nil
        pendingInputIngress.removeAll(keepingCapacity: false)
    }

    func updateSurfaceFocus(_ isFocused: Bool) {
        surfaceHasFocus = isFocused
    }

    private func bindSessionStreams(_ session: MoonlightSession) {
        eventTask?.cancel()

        eventTask = Task { [weak self] in
            let events = await session.events
            for await event in events {
                guard let self else { return }
                self.handle(event: event)
            }
        }
    }

    private func startRuntimeSnapshotPolling(_ runtime: SessionRuntime) {
        runtimeSnapshotTask?.cancel()
        runtimeSnapshotTask = Task { [weak self] in
            while !Task.isCancelled {
                let snapshot = await runtime.snapshot()
                await MainActor.run {
                    self?.latestMetrics = """
                    control messages: \(snapshot.controlMessagesObserved)
                    video packets: \(snapshot.videoPacketsObserved)
                    audio packets: \(snapshot.audioPacketsObserved)
                    concealment: \(snapshot.audioConcealmentPackets)
                    missing video/audio: \(snapshot.missingVideoPackets)/\(snapshot.missingAudioPackets)
                    reordered video/audio: \(snapshot.reorderedVideoPackets)/\(snapshot.reorderedAudioPackets)
                    discontinuities: \(snapshot.videoDiscontinuityEvents)
                    reconnects: \(snapshot.reconnectAttempts)
                    unexpected disconnect: \(snapshot.unexpectedDisconnect)
                    """
                }

                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    private func handle(event: SessionEvent) {
        switch event {
        case .stateChanged(let state):
            status = "Session state: \(stateDescription(state))"
            appendLog("Event: session state -> \(stateDescription(state))")
        case .videoFormatChanged(let format):
            currentVideoDimensions = format.dimensions
            appendLog("Event: video format -> \(Int(format.dimensions.width))x\(Int(format.dimensions.height)) \(format.codec)")
        case .audioFormatChanged(let format):
            appendLog("Event: audio format -> \(format.sampleRate) Hz / \(format.channelCount) ch")
        case .hdrModeChanged(let update):
            appendLog("Event: HDR mode -> \(update.enabled ? "enabled" : "disabled")")
        case .controllerFeedback(let feedback):
            appendLog("Event: controller feedback -> id \(feedback.controllerID), \(feedbackEffectDescription(feedback.effect))")
        case .warning(let warning):
            appendLog("Warning: \(warning.message)")
        case .failed(let error):
            appendLog("Failure: \(error.message)")
        }
    }

    private func feedbackEffectDescription(_ effect: ControllerFeedbackEffect) -> String {
        switch effect {
        case .capabilities(let supportsRumble):
            return "capabilities rumble=\(supportsRumble)"
        case .rumble(let low, let high):
            return "rumble low=\(low) high=\(high)"
        case .triggerRumble(let left, let right):
            return "trigger rumble left=\(left) right=\(right)"
        case .motionReport(let motionType, let reportRateHz):
            return "motion type=\(motionType) rate=\(reportRateHz)Hz"
        case .led(let red, let green, let blue):
            return "led rgb=(\(red),\(green),\(blue))"
        case .adaptiveTriggers(let flags, let leftType, let rightType, let leftPayload, let rightPayload):
            return "adaptive triggers flags=\(flags) types=(\(leftType),\(rightType)) payloads=\(leftPayload.count)/\(rightPayload.count)"
        }
    }

    private func handle(metrics snapshot: SessionMetricsSnapshot) {
        latestMetrics = """
        open: \(snapshot.sessionOpenDurationMs.map(String.init) ?? "-") ms
        channels: \(snapshot.establishedChannelCount)
        input packets: \(snapshot.inputPacketsSent) / events: \(snapshot.inputEventsSent)
        avg input queue/send: \(formatMilliseconds(snapshot.averageInputQueueLatencyMs)) / \(formatMilliseconds(snapshot.averageInputTransportLatencyMs))
        video packets: \(snapshot.videoPacketsObserved) / decoded: \(snapshot.decodedVideoFrames) / rendered: \(snapshot.renderedVideoFrames)
        audio packets: \(snapshot.audioPacketsObserved) / decoded: \(snapshot.decodedAudioBuffers) / played: \(snapshot.playedAudioBuffers)
        avg video decode: \(formatMilliseconds(snapshot.averageVideoDecodeLatencyMs))
        avg host processing: \(formatMilliseconds(snapshot.averageHostProcessingLatencyMs))
        avg audio decode: \(formatMilliseconds(snapshot.averageAudioDecodeLatencyMs))
        reordered video/audio: \(snapshot.reorderedVideoPackets)/\(snapshot.reorderedAudioPackets)
        missing video/audio: \(snapshot.missingVideoPackets)/\(snapshot.missingAudioPackets)
        discontinuities: \(snapshot.videoDiscontinuityEvents)
        reconnects: \(snapshot.reconnectAttempts)
        underruns: \(snapshot.audioUnderrunEvents)
        """
    }

    private func runOperation(_ statusText: String, operation: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            status = statusText
            do {
                try await operation()
            } catch let error as MoonlightError {
                status = "Error"
                appendLog("Error: \(error.message)")
            } catch {
                status = "Error"
                appendLog("Error: \(error.localizedDescription)")
            }
        }
    }

    private func parseManualEndpoint() throws -> HostEndpoint {
        let trimmed = manualHostAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MoonlightError(.unsupportedOperation, message: "Host field must not be empty")
        }

        if let url = URL(string: trimmed), let host = url.host {
            return HostEndpoint(address: host, port: url.port ?? 47989)
        }

        if let separator = trimmed.lastIndex(of: ":"), separator != trimmed.startIndex {
            let host = String(trimmed[..<separator])
            let portString = String(trimmed[trimmed.index(after: separator)...])
            if let port = Int(portString) {
                return HostEndpoint(address: host, port: port)
            }
        }

        return HostEndpoint(address: trimmed, port: 47989)
    }

    private func replaceHost(_ host: MoonlightHost) {
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else if let index = hosts.firstIndex(where: { $0.endpoint == host.endpoint }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        if selectedHostID == nil {
            selectedHostID = host.id
        }
    }

    private func ensureSelectedHostID() async throws -> HostID {
        guard let selectedHostID else {
            throw MoonlightError(.hostNotFound, message: "Select a host first")
        }
        guard let selectedHost = hosts.first(where: { $0.id == selectedHostID }) else {
            throw MoonlightError(.hostNotFound, message: "Selected host is no longer available")
        }
        guard let hostStore else {
            return selectedHostID
        }

        var storedHosts = try await hostStore.loadHosts()
        if !storedHosts.contains(where: { $0.id == selectedHostID }) {
            if let existingIndex = storedHosts.firstIndex(where: { $0.endpoint == selectedHost.endpoint }) {
                storedHosts[existingIndex] = selectedHost
            } else {
                storedHosts.append(selectedHost)
            }
            try await hostStore.saveHosts(storedHosts)
            appendLog("Repaired missing host entry for \(selectedHost.endpoint.address):\(selectedHost.endpoint.port)")
        }
        return selectedHostID
    }

    private func requireSelectedHost() throws -> MoonlightHost {
        guard let selectedHostID else {
            throw MoonlightError(.hostNotFound, message: "Select a host first")
        }
        guard let selectedHost = hosts.first(where: { $0.id == selectedHostID }) else {
            throw MoonlightError(.hostNotFound, message: "Selected host is no longer available")
        }
        return selectedHost
    }

    private func resolveStoredHostID() async throws -> HostID {
        let selectedHostID = try await ensureSelectedHostID()
        guard let selectedHost = hosts.first(where: { $0.id == selectedHostID }) else {
            throw MoonlightError(.hostNotFound, message: "Selected host is no longer available")
        }
        guard let hostStore else {
            return selectedHostID
        }

        let storedHosts = try await hostStore.loadHosts()
        if let exact = storedHosts.first(where: { $0.id == selectedHostID }) {
            return exact.id
        }
        if let matchingEndpointHost = storedHosts.first(where: { $0.endpoint == selectedHost.endpoint }) {
            if selectedHostID != matchingEndpointHost.id {
                self.selectedHostID = matchingEndpointHost.id
                self.replaceHost(matchingEndpointHost)
                appendLog("Resolved host selection to stored host ID \(matchingEndpointHost.id.rawValue)")
            }
            return matchingEndpointHost.id
        }
        return selectedHostID
    }

    private func logStoredHosts(context: String) async {
        guard let hostStore else { return }
        do {
            let path = await hostStore.debugFilePath()
            let storedHosts = try await hostStore.loadHosts()
            let summary = storedHosts
                .map { "\($0.name) \($0.endpoint.address):\($0.endpoint.port) \($0.id.rawValue)" }
                .joined(separator: " | ")
            appendLog("\(context) store path: \(path)")
            appendLog("\(context) store hosts: \(summary.isEmpty ? "<empty>" : summary)")
        } catch {
            appendLog("\(context) store read failed: \(error.localizedDescription)")
        }
    }

    private func appendLog(_ line: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        logLines.append("[\(timestamp)] \(line)")
        if logLines.count > 300 {
            logLines.removeFirst(logLines.count - 300)
        }
    }

    private func recordInputFailure(_ message: String) {
        appendLog(message)
    }

    private func formatMilliseconds(_ value: Double?) -> String {
        guard let value else { return "-" }
        return String(format: "%.2f ms", value)
    }

    private func logSocketPorts(_ sockets: ChannelSocketSet) async {
        do {
            if let controlTransport = sockets.controlTransport {
                appendLog("Control socket local port: \(try await controlTransport.localPort())")
            }
            if let inputTransport = sockets.inputTransport {
                appendLog("Input socket local port: \(try await inputTransport.localPort())")
            }
            if let videoSource = sockets.videoSource {
                appendLog("Video socket local port: \(try await videoSource.localPort())")
            }
            if let audioSource = sockets.audioSource {
                appendLog("Audio socket local port: \(try await audioSource.localPort())")
            }
        } catch {
            appendLog("Socket port inspection failed: \(error.localizedDescription)")
        }
    }

    private static func generatePIN() -> String {
        String(format: "%04d", Int.random(in: 0...9999))
    }

    private func hostKindDescription(_ kind: HostKind) -> String {
        switch kind {
        case .sunshine: return "Sunshine"
        case .apollo: return "Apollo"
        case .unknown: return "Unknown"
        }
    }

    private func pairingStateDescription(_ state: PairingState) -> String {
        switch state {
        case .paired: return "paired"
        case .unpaired: return "unpaired"
        case .unknown: return "unknown"
        }
    }

    private func stateDescription(_ state: SessionState) -> String {
        switch state {
        case .idle: return "idle"
        case .discovering: return "discovering"
        case .pairing: return "pairing"
        case .paired: return "paired"
        case .launching: return "launching"
        case .connecting: return "connecting"
        case .streaming: return "streaming"
        case .stopping: return "stopping"
        case .stopped: return "stopped"
        case .failed: return "failed"
        }
    }

    var selectedHost: MoonlightHost? {
        guard let selectedHostID else { return nil }
        return hosts.first(where: { $0.id == selectedHostID })
    }

    var hasActiveSession: Bool {
        session != nil || preparedRuntime != nil
    }

    private static func samePixelSize(_ lhs: CGSize, _ rhs: CGSize?) -> Bool {
        guard let rhs else {
            return false
        }

        return Int(lhs.width.rounded()) == Int(rhs.width.rounded())
            && Int(lhs.height.rounded()) == Int(rhs.height.rounded())
    }
}

#endif
