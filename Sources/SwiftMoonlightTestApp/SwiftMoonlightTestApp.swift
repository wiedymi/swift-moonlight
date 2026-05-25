#if os(macOS)
import AppKit
import Metal
import QuartzCore
import SwiftMoonlight
import SwiftUI

/// Safety invariant:
/// - The test app owns the CAMetalLayer used for rendering.
/// - Once a session starts, the layer is only handed to the SwiftMoonlight rendering path.
private struct UnsafeSendableMetalLayerReference: @unchecked Sendable {
    let layer: CAMetalLayer
}

private struct AutoStartConfiguration {
    let enabled: Bool
    let hostOverride: HostEndpoint?
    let appIDOverride: RemoteApp.ID?

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AutoStartConfiguration {
        let enabled = environment["SWIFT_MOONLIGHT_TEST_APP_AUTOSTART"] == "1"
        let hostOverride: HostEndpoint?
        if let rawValue = environment["SWIFT_MOONLIGHT_TEST_HOST"], !rawValue.isEmpty {
            if let url = URL(string: rawValue), let host = url.host {
                hostOverride = HostEndpoint(address: host, port: url.port ?? 47_989)
            } else if let separator = rawValue.lastIndex(of: ":"), separator != rawValue.startIndex,
                      let port = Int(rawValue[rawValue.index(after: separator)...]) {
                hostOverride = HostEndpoint(address: String(rawValue[..<separator]), port: port)
            } else {
                hostOverride = HostEndpoint(address: rawValue, port: 47_989)
            }
        } else {
            hostOverride = nil
        }
        let appIDOverride = environment["SWIFT_MOONLIGHT_TEST_APP_ID"].flatMap {
            $0.isEmpty ? nil : $0
        }
        return AutoStartConfiguration(
            enabled: enabled,
            hostOverride: hostOverride,
            appIDOverride: appIDOverride
        )
    }
}

enum TestAppMouseMode: String, CaseIterable, Identifiable {
    case direct
    case captured

    var id: Self { self }

    var title: String {
        switch self {
        case .direct:
            return "Direct"
        case .captured:
            return "Captured"
        }
    }

    var detail: String {
        switch self {
        case .direct:
            return "Absolute pointer positioning for touch-like desktop tests."
        case .captured:
            return "Relative mouse capture for physical mouse input."
        }
    }
}

enum TestAppResolutionPreset: String, CaseIterable, Identifiable, Codable {
    case streamWindow
    case hd720
    case fullHD1080
    case qhd1440
    case uhd4k

    var id: Self { self }

    var title: String {
        switch self {
        case .streamWindow:
            return "Window"
        case .hd720:
            return "1280×720"
        case .fullHD1080:
            return "1920×1080"
        case .qhd1440:
            return "2560×1440"
        case .uhd4k:
            return "3840×2160"
        }
    }

    var dimensions: CGSize {
        resolvedDimensions(fitting: nil)
    }

    func resolvedDimensions(fitting surfaceSize: CGSize?) -> CGSize {
        switch self {
        case .streamWindow:
            return Self.sanitizedWindowDimensions(surfaceSize ?? CGSize(width: 1920, height: 1080))
        case .hd720:
            return CGSize(width: 1280, height: 720)
        case .fullHD1080:
            return CGSize(width: 1920, height: 1080)
        case .qhd1440:
            return CGSize(width: 2560, height: 1440)
        case .uhd4k:
            return CGSize(width: 3840, height: 2160)
        }
    }

    private static func sanitizedWindowDimensions(_ size: CGSize) -> CGSize {
        let width = sanitizedEvenDimension(size.width, minimum: 640, maximum: 7680)
        let height = sanitizedEvenDimension(size.height, minimum: 360, maximum: 4320)
        return CGSize(width: width, height: height)
    }

    private static func sanitizedEvenDimension(_ value: CGFloat, minimum: Int, maximum: Int) -> Int {
        let rounded = Int(value.rounded(.toNearestOrAwayFromZero))
        let clamped = min(max(rounded, minimum), maximum)
        return clamped.isMultiple(of: 2) ? clamped : clamped - 1
    }
}

enum TestAppFrameRatePreset: Int, CaseIterable, Identifiable, Codable {
    case fps30 = 30
    case fps60 = 60
    case fps90 = 90
    case fps120 = 120

    var id: Int { rawValue }

    var title: String {
        "\(rawValue) FPS"
    }
}

enum TestAppVideoCodecPreference: String, CaseIterable, Identifiable, Codable {
    case auto
    case hevc
    case h264
    case av1

    var id: Self { self }

    var title: String {
        switch self {
        case .auto:
            return "Auto"
        case .hevc:
            return "HEVC"
        case .h264:
            return "H.264"
        case .av1:
            return "AV1"
        }
    }

    var streamPreference: [VideoCodec] {
        switch self {
        case .auto:
            return [.hevc, .h264]
        case .hevc:
            return [.hevc, .h264]
        case .h264:
            return [.h264]
        case .av1:
            return [.av1, .hevc, .h264]
        }
    }
}

enum TestAppAudioModePreset: String, CaseIterable, Identifiable, Codable {
    case stereo
    case surround51
    case surround71

    var id: Self { self }

    var title: String {
        switch self {
        case .stereo:
            return "Stereo"
        case .surround51:
            return "5.1"
        case .surround71:
            return "7.1"
        }
    }

    var audioMode: AudioMode {
        switch self {
        case .stereo:
            return .stereo
        case .surround51:
            return .surround51
        case .surround71:
            return .surround71
        }
    }
}

enum TestAppDynamicRangePreset: String, CaseIterable, Identifiable, Codable {
    case sdr
    case hdr

    var id: Self { self }

    var title: String {
        switch self {
        case .sdr:
            return "SDR"
        case .hdr:
            return "HDR"
        }
    }

    var dynamicRange: DynamicRangePreference {
        switch self {
        case .sdr:
            return .sdr
        case .hdr:
            return .hdr
        }
    }
}

enum TestAppDecodeModePreset: String, CaseIterable, Identifiable, Codable {
    case hardwareFirst
    case hardwareOnly
    case softwareFallback

    var id: Self { self }

    var title: String {
        switch self {
        case .hardwareFirst:
            return "Hardware First"
        case .hardwareOnly:
            return "Hardware Only"
        case .softwareFallback:
            return "Software Fallback"
        }
    }

    var decodeMode: DecodeModePreference {
        switch self {
        case .hardwareFirst:
            return .hardwareFirst
        case .hardwareOnly:
            return .hardwareOnly
        case .softwareFallback:
            return .softwareFallback
        }
    }
}

struct TestAppStreamSettings: Codable, Equatable {
    var resolution: TestAppResolutionPreset
    var frameRate: TestAppFrameRatePreset
    var bitrateKbps: Int
    var videoCodec: TestAppVideoCodecPreference
    var audioMode: TestAppAudioModePreset
    var dynamicRange: TestAppDynamicRangePreset
    var decodeMode: TestAppDecodeModePreset
    var openFullscreenOnStart: Bool

    static let `default` = TestAppStreamSettings(
        resolution: .streamWindow,
        frameRate: .fps60,
        bitrateKbps: 20_000,
        videoCodec: .auto,
        audioMode: .stereo,
        dynamicRange: .sdr,
        decodeMode: .hardwareFirst,
        openFullscreenOnStart: true
    )

    var sanitized: TestAppStreamSettings {
        var copy = self
        copy.bitrateKbps = min(max(copy.bitrateKbps, 1_000), 150_000)
        return copy
    }

    var streamConfiguration: StreamConfiguration {
        streamConfiguration(surfaceSize: nil)
    }

    func streamConfiguration(surfaceSize: CGSize?) -> StreamConfiguration {
        StreamConfiguration(
            resolution: resolution.resolvedDimensions(fitting: surfaceSize),
            frameRate: frameRate.rawValue,
            bitrateKbps: bitrateKbps,
            dynamicRange: dynamicRange.dynamicRange,
            videoCodecPreference: videoCodec.streamPreference,
            audioMode: audioMode.audioMode,
            preferredDecodeMode: decodeMode.decodeMode,
            enableControlEncryption: true,
            enableVideoEncryption: true,
            enableAudioEncryption: true
        )
    }

    var summary: String {
        "\(resolution.title) • \(frameRate.title) • \(bitrateKbps) Kbps • \(videoCodec.title) • \(audioMode.title)"
    }
}

enum TestAppStreamSettingsStore {
    private static let defaultsKey = "swiftMoonlightTestApp.streamSettings"

    static func load() -> TestAppStreamSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(TestAppStreamSettings.self, from: data)
        else {
            return .default
        }
        return settings.sanitized
    }

    static func save(_ settings: TestAppStreamSettings) {
        guard let data = try? JSONEncoder().encode(settings) else {
            return
        }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

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

struct TestAppRootView: View {
    @StateObject private var model: TestAppModel

    init() {
        let model: TestAppModel
        do {
            model = try TestAppModel.makeDefault()
        } catch {
            model = TestAppModel(client: nil, hostStore: nil, device: MTLCreateSystemDefaultDevice(), initializationError: error)
        }
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        NavigationSplitView {
            TestAppSidebarShell(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 300)
        } detail: {
            TestAppWorkspaceView(model: model)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1100, minHeight: 760)
        .background(TestAppTheme.canvas)
        .tint(TestAppTheme.accent)
        .background(
            TestAppMainWindowChromeBridge(
                windowTitle: "swift-moonlight test app",
                backgroundColor: TestAppTheme.canvas
            )
            .frame(width: 0, height: 0)
        )
        .task {
            model.loadStoredHosts()
        }
    }
}

private struct TestAppSidebarShell: View {
    @ObservedObject var model: TestAppModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("HOSTS")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    Spacer(minLength: 8)

                    TestAppCountPill(count: model.hosts.count)
                }
                .padding(.horizontal, 12)

                HStack(spacing: 8) {
                    TestAppInlineIconButton(title: "Discover", systemImage: "dot.radiowaves.left.and.right") {
                        model.discoverHosts()
                    }
                    TestAppInlineIconButton(title: "Refresh", systemImage: "arrow.clockwise") {
                        model.refreshSelectedHost()
                    }
                    .disabled(model.selectedHost == nil)

                    Spacer(minLength: 8)

                    TestAppInlineIconButton(title: "Settings", systemImage: "gearshape") {
                        model.presentSettingsWindow()
                    }
                }
                .padding(.horizontal, 12)
            }
            .padding(.top, 12)
            .padding(.bottom, 6)

            if model.hosts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No hosts")
                        .font(.body)
                    Text("Discover Sunshine or Apollo hosts, or add one manually in the detail pane.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(model.hosts) { host in
                            Button {
                                model.selectHost(host.id)
                            } label: {
                                TestAppHostRow(
                                    host: host,
                                    isSelected: model.selectedHostID == host.id,
                                    isStreaming: model.hasActiveSession && model.selectedHostID == host.id
                                )
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 2)
                }
            }

            Spacer(minLength: 0)

            VStack(spacing: 8) {
                Button {
                    model.presentStreamWindow()
                } label: {
                    Label("Open Stream", systemImage: "display")
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)

                HStack(spacing: 8) {
                    Button("Fetch Apps") {
                        model.fetchApps()
                    }
                    .disabled(model.selectedHost == nil)

                    Button("Settings") {
                        model.presentSettingsWindow()
                    }
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TestAppTheme.sidebar.ignoresSafeArea())
    }
}

private struct TestAppWorkspaceView: View {
    @ObservedObject var model: TestAppModel

    var body: some View {
        ZStack {
            TestAppTheme.canvas.ignoresSafeArea()

            if let selectedHost = model.selectedHost {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        TestAppHostSummaryPanel(model: model, host: selectedHost)
                        HStack(alignment: .top, spacing: 18) {
                            TestAppAppsWorkspacePanel(model: model)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            TestAppControlRail(model: model)
                                .frame(width: 340)
                        }

                        TestAppDiagnosticsWorkspacePanel(model: model)
                    }
                    .padding(20)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        TestAppPanel("Library") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Add or discover a host")
                                    .font(.headline)
                                Text("The layout mirrors ViviTerm’s split view: hosts stay in the sidebar, and setup/app launch lives in the detail view.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                HStack(spacing: 10) {
                                    TextField("host or host:port", text: $model.manualHostAddress)
                                        .textFieldStyle(.plain)
                                    Button("Add") {
                                        model.addManualHost()
                                    }
                                    .disabled(model.manualHostAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(TestAppTheme.inlineFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(TestAppTheme.inlineStroke, lineWidth: 0.8)
                                )

                                HStack(spacing: 8) {
                                    Button("Discover Hosts") {
                                        model.discoverHosts()
                                    }
                                    .buttonStyle(.borderedProminent)

                                    Button("Open Stream Window") {
                                        model.presentStreamWindow()
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
    }
}

private struct TestAppHostSummaryPanel: View {
    @ObservedObject var model: TestAppModel
    let host: MoonlightHost

    private var selectedApp: RemoteApp? {
        model.apps.first(where: { $0.id == model.selectedAppID })
    }

    var body: some View {
        TestAppPanel("Session") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(host.name)
                            .font(.title2.weight(.semibold))
                        Text("\(host.endpoint.address):\(host.endpoint.port)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        TestAppPillBadge(text: hostKindTitle(host.kind), tint: .blue)
                        TestAppPillBadge(
                            text: pairingTitle(host.pairingState),
                            tint: host.pairingState.isPaired ? .green : .orange
                        )
                    }
                }

                Divider()

                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Status")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(model.status)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Selected App")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(selectedApp?.name ?? "No app selected")
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Stream Profile")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(model.streamSettings.summary)
                    }
                }
            }
        }
    }
}

private struct TestAppAppsWorkspacePanel: View {
    @ObservedObject var model: TestAppModel

    private var selectedApp: RemoteApp? {
        model.apps.first(where: { $0.id == model.selectedAppID })
    }

    var body: some View {
        TestAppPanel("Apps") {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(model.apps) { app in
                            Button {
                                model.selectedAppID = app.id
                            } label: {
                                TestAppAppRow(app: app, isSelected: model.selectedAppID == app.id)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(minHeight: 320)

                HStack {
                    Button("Fetch Apps") { model.fetchApps() }
                        .buttonStyle(.borderedProminent)
                    Button("Start Session") { model.startSelectedApp() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.selectedAppID == nil)
                    Button("Stop") { model.stopSession() }
                        .disabled(!model.hasActiveSession)
                }
            }
        }
    }
}

private struct TestAppControlRail: View {
    @ObservedObject var model: TestAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            TestAppPanel("Launch") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.apps.first(where: { $0.id == model.selectedAppID })?.name ?? "Select an app")
                        .font(.headline)
                    Text(model.apps.first(where: { $0.id == model.selectedAppID })?.id ?? "Fetch the app list to start a session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Button("Open Stream") {
                            model.presentStreamWindow()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Settings") {
                            model.presentSettingsWindow()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            TestAppPanel("Host Tools") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Button("Discover") { model.discoverHosts() }
                            .buttonStyle(.bordered)
                        Button("Refresh") { model.refreshSelectedHost() }
                            .buttonStyle(.bordered)
                            .disabled(model.selectedHost == nil)
                    }

                    HStack(spacing: 10) {
                        TextField("host or host:port", text: $model.manualHostAddress)
                            .textFieldStyle(.plain)
                        Button("Add") { model.addManualHost() }
                            .disabled(model.manualHostAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(TestAppTheme.inlineFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(TestAppTheme.inlineStroke, lineWidth: 0.8)
                    )
                }
            }

            TestAppPanel("Pairing") {
                VStack(alignment: .leading, spacing: 12) {
                    SecureField("PIN", text: $model.pin)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Apollo passphrase (optional)", text: $model.passphrase)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 8) {
                        Button("Pair") { model.pairSelectedHost() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.selectedHost == nil)
                        Button("Unpair") { model.unpairSelectedHost() }
                            .buttonStyle(.bordered)
                            .disabled(model.selectedHost == nil)
                    }
                }
            }

            TestAppPanel("Profile") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.streamSettings.summary)
                    Text("Mouse: \(model.mouseMode.title) • Local cursor: \(model.showLocalCursor ? "shown" : "hidden")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(model.currentVideoDimensions.map { "Video: \(Int($0.width))×\(Int($0.height))" } ?? "Video: no active stream")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(model.surfaceHasFocus ? "Stream window focused for input" : "Focus the stream window before typing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct TestAppDiagnosticsWorkspacePanel: View {
    @ObservedObject var model: TestAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                TestAppPanel("Metrics") {
                    ScrollView {
                        Text(model.latestMetrics)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 220)
                }

                TestAppPanel("Status") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(model.status)
                            .font(.headline)
                        Text(model.currentVideoDimensions.map { "\(Int($0.width))×\(Int($0.height))" } ?? "No active stream")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 280)
            }

            TestAppPanel("Logs") {
                ScrollView {
                    Text(model.logLines.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 320)
            }
        }
    }
}

private struct TestAppSectionLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(1.1)
            .foregroundStyle(.secondary)
    }
}

private struct TestAppHostRow: View {
    let host: MoonlightHost
    let isSelected: Bool
    let isStreaming: Bool

    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "display.2")
                .foregroundStyle(isSelected ? selectedForegroundColor : .secondary)
                .imageScale(.medium)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(host.name)
                    .font(.body)
                    .foregroundStyle(isSelected ? selectedForegroundColor : .primary)
                    .lineLimit(1)

                Text("\(host.endpoint.address):\(host.endpoint.port) • \(hostKindTitle(host.kind)) • \(pairingTitle(host.pairingState))")
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.75))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isStreaming {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("LIVE")
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(sessionIndicatorColor)
            } else {
                Image(systemName: host.pairingState.isPaired ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(host.pairingState.isPaired ? .green : .secondary)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .background(selectionBackground)
    }

    private var selectedForegroundColor: Color {
        controlActiveState == .key ? .accentColor : .accentColor.opacity(0.78)
    }

    private var selectionFillColor: Color {
        let base = NSColor.unemphasizedSelectedContentBackgroundColor
        let alpha: Double = controlActiveState == .key ? 0.26 : 0.18
        return Color(nsColor: base).opacity(alpha)
    }

    private var sessionIndicatorColor: Color {
        isSelected ? selectedForegroundColor.opacity(0.9) : .secondary
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selectionFillColor)
        }
    }
}

private struct TestAppAppRow: View {
    let app: RemoteApp
    let isSelected: Bool

    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(isSelected ? selectedForegroundColor : .secondary)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.body)
                    .foregroundStyle(isSelected ? selectedForegroundColor : .primary)
                Text(app.id)
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.75))
            }

            Spacer(minLength: 8)
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .background(selectionBackground)
    }

    private var selectedForegroundColor: Color {
        controlActiveState == .key ? .accentColor : .accentColor.opacity(0.78)
    }

    private var selectionFillColor: Color {
        let base = NSColor.unemphasizedSelectedContentBackgroundColor
        let alpha: Double = controlActiveState == .key ? 0.26 : 0.18
        return Color(nsColor: base).opacity(alpha)
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selectionFillColor)
        }
    }
}

private struct TestAppInlineIconButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(TestAppTheme.inlineFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(TestAppTheme.inlineStroke, lineWidth: 0.8)
                )
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

private struct TestAppCountPill: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(TestAppTheme.inlineFill, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(TestAppTheme.inlineStroke, lineWidth: 0.8)
            )
    }
}

struct TestAppPanel<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TestAppSectionLabel(title)
            content
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(TestAppTheme.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(TestAppTheme.panelBorder, lineWidth: 0.8)
                )
        )
    }
}

private struct TestAppPillBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
    }
}

struct TestAppSurfaceBadge: View {
    let headline: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headline)
                .font(.caption.weight(.semibold))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private func hostKindTitle(_ kind: HostKind) -> String {
    switch kind {
    case .sunshine:
        return "Sunshine"
    case .apollo:
        return "Apollo"
    case .unknown:
        return "Unknown"
    }
}

private func pairingTitle(_ state: PairingState) -> String {
    switch state {
    case .paired:
        return "Paired"
    case .unpaired:
        return "Unpaired"
    case .unknown:
        return "Unknown"
    }
}

@main
struct SwiftMoonlightTestApp: App {
    var body: some Scene {
        WindowGroup("swift-moonlight test app") {
            TestAppRootView()
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1260, height: 820)
    }
}
#endif
