import Foundation

public struct TestClock: Clock {
    public var date: Date

    public init(date: Date = Date(timeIntervalSince1970: 0)) {
        self.date = date
    }

    public func now() -> Date {
        date
    }
}

public struct AdvancingTestClock: Clock {
    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var dates: [Date]
        private var fallback: Date

        init(dates: [Date]) {
            self.dates = dates
            self.fallback = dates.last ?? Date(timeIntervalSince1970: 0)
        }

        func next() -> Date {
            lock.lock()
            defer { lock.unlock() }
            guard !dates.isEmpty else {
                return fallback
            }
            let value = dates.removeFirst()
            fallback = value
            return value
        }
    }

    private let storage: Storage

    public init(dates: [Date]) {
        storage = Storage(dates: dates)
    }

    public func now() -> Date {
        storage.next()
    }
}

public actor InMemoryHostStore: HostStore {
    private var hosts: [MoonlightHost]

    public init(hosts: [MoonlightHost] = []) {
        self.hosts = hosts
    }

    public func loadHosts() async throws -> [MoonlightHost] {
        hosts
    }

    public func saveHosts(_ hosts: [MoonlightHost]) async throws {
        self.hosts = hosts
    }
}

public actor FixtureHostDiscovery: HostDiscovery {
    private let discoveredHosts: [DiscoveredHost]

    public init(discoveredHosts: [DiscoveredHost]) {
        self.discoveredHosts = discoveredHosts
    }

    public func discover(timeout: Duration) async throws -> [DiscoveredHost] {
        _ = timeout
        return discoveredHosts
    }
}

public actor InMemoryIdentityStore: IdentityStore {
    private var identity: ClientIdentity?

    public init(identity: ClientIdentity? = nil) {
        self.identity = identity
    }

    public func loadOrCreateIdentity() async throws -> ClientIdentity {
        if let identity {
            return identity
        }

        let newIdentity = ClientIdentity()
        identity = newIdentity
        return newIdentity
    }

    public func clearIdentity() async throws {
        identity = nil
    }
}

public struct TestLogger: MoonlightLogger {
    public init() {}

    public func debug(_ message: String) { _ = message }
    public func info(_ message: String) { _ = message }
    public func warning(_ message: String) { _ = message }
    public func error(_ message: String) { _ = message }
}

public actor RecordingMetricsSink: MetricsSink {
    private var snapshots: [SessionMetricsSnapshot]

    public init(snapshots: [SessionMetricsSnapshot] = []) {
        self.snapshots = snapshots
    }

    public func record(_ snapshot: SessionMetricsSnapshot) async {
        snapshots.append(snapshot)
    }

    public func recordedSnapshots() -> [SessionMetricsSnapshot] {
        snapshots
    }
}

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

public actor RecordingInputTransport: InputPacketTransport {
    private var packets: [(packet: Data, channelID: UInt8, reliable: Bool)] = []

    public init() {}

    public func send(_ packet: Data, channelID: UInt8, reliable: Bool) async throws {
        packets.append((packet, channelID, reliable))
    }

    public func recordedPackets() -> [(packet: Data, channelID: UInt8, reliable: Bool)] {
        packets
    }
}

public actor FixtureHostService: HostService {
    private let serverInfoData: Data
    private let appListData: Data
    private var cancelledHostIDs: [HostID] = []

    public init(serverInfoData: Data, appListData: Data) {
        self.serverInfoData = serverInfoData
        self.appListData = appListData
    }

    public func fetchServerInfo(for host: MoonlightHost) async throws -> Data {
        _ = host
        return serverInfoData
    }

    public func fetchAppList(for host: MoonlightHost) async throws -> Data {
        _ = host
        return appListData
    }

    public func cancelCurrentApp(for host: MoonlightHost) async throws {
        cancelledHostIDs.append(host.id)
    }

    public func recordedCancelledHostIDs() -> [HostID] {
        cancelledHostIDs
    }
}

public actor FixtureSessionService: SessionService {
    private let negotiatedSession: NegotiatedSession
    private var launchedHostIDs: [HostID] = []
    private var launchedAppIDs: [RemoteApp.ID] = []
    private var launchConfigurations: [StreamConfiguration] = []

    public init(negotiatedSession: NegotiatedSession) {
        self.negotiatedSession = negotiatedSession
    }

    public func launchSession(
        for host: MoonlightHost,
        appID: RemoteApp.ID,
        configuration: StreamConfiguration,
        identity: ClientIdentity
    ) async throws -> NegotiatedSession {
        _ = identity
        launchedHostIDs.append(host.id)
        launchedAppIDs.append(appID)
        launchConfigurations.append(configuration)
        return negotiatedSession
    }

    public func recordedHostIDs() -> [HostID] {
        launchedHostIDs
    }

    public func recordedAppIDs() -> [RemoteApp.ID] {
        launchedAppIDs
    }

    public func recordedConfigurations() -> [StreamConfiguration] {
        launchConfigurations
    }
}

public actor RecordingLaunchTransport: SessionLaunchTransport {
    private let responseData: Data
    private var requests: [(hostID: HostID, queryItems: [URLQueryItem])] = []

    public init(responseData: Data) {
        self.responseData = responseData
    }

    public func sendLaunchRequest(
        to host: MoonlightHost,
        queryItems: [URLQueryItem]
    ) async throws -> Data {
        requests.append((host.id, queryItems))
        return responseData
    }

    public func recordedRequests() -> [(hostID: HostID, queryItems: [URLQueryItem])] {
        requests
    }
}

public actor RecordingHTTPClient: HTTPClient {
    public struct Response: Sendable {
        public var data: Data
        public var statusCode: Int

        public init(data: Data, statusCode: Int = 200) {
            self.data = data
            self.statusCode = statusCode
        }
    }

    private let response: Response
    private var requests: [(url: URL, headers: [String: String])] = []

    public init(response: Response) {
        self.response = response
    }

    public func get(url: URL, headers: [String : String]) async throws -> (Data, HTTPURLResponse) {
        requests.append((url, headers))
        let response = HTTPURLResponse(
            url: url,
            statusCode: self.response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )!
        return (self.response.data, response)
    }

    public func recordedRequests() -> [(url: URL, headers: [String: String])] {
        requests
    }
}

public actor FixturePairingTransport: PairingTransport {
    private let responses: [Data]
    private var index = 0
    private var requests: [(hostID: HostID, queryItems: [URLQueryItem])] = []
    private var unpairRequests: [(hostID: HostID, queryItems: [URLQueryItem])] = []

    public init(responses: [Data]) {
        self.responses = responses
    }

    public func sendPairingRequest(
        to host: MoonlightHost,
        queryItems: [URLQueryItem]
    ) async throws -> Data {
        requests.append((host.id, queryItems))
        guard index < responses.count else {
            throw MoonlightError(.pairingRejected, message: "No more fixture pairing responses available")
        }
        defer { index += 1 }
        return responses[index]
    }

    public func recordedRequests() -> [(hostID: HostID, queryItems: [URLQueryItem])] {
        requests
    }

    public func sendUnpairRequest(
        to host: MoonlightHost,
        queryItems: [URLQueryItem]
    ) async throws -> Data {
        unpairRequests.append((host.id, queryItems))
        return Data()
    }

    public func recordedUnpairRequests() -> [(hostID: HostID, queryItems: [URLQueryItem])] {
        unpairRequests
    }
}

public actor FixturePairingClientService: PairingClientService {
    private let result: PairingResult
    private var requests: [(hostID: HostID, auth: PairingAuth, identityID: UUID)] = []
    private var unpairRequests: [(hostID: HostID, identityID: UUID)] = []

    public init(result: PairingResult) {
        self.result = result
    }

    public func pair(host: MoonlightHost, auth: PairingAuth, identity: ClientIdentity) async throws -> PairingResult {
        requests.append((host.id, auth, identity.identifier))
        return result
    }

    public func recordedRequests() -> [(hostID: HostID, auth: PairingAuth, identityID: UUID)] {
        requests
    }

    public func unpair(host: MoonlightHost, identity: ClientIdentity) async throws {
        unpairRequests.append((host.id, identity.identifier))
    }

    public func recordedUnpairRequests() -> [(hostID: HostID, identityID: UUID)] {
        unpairRequests
    }
}

public actor FixtureRTSPTransport: RTSPTransport {
    private let responses: [RTSPResponse]
    private var index = 0
    private var requests: [RTSPRequest] = []
    private var encryptionKeys: [Data?] = []

    public init(responses: [RTSPResponse]) {
        self.responses = responses
    }

    public func transact(sessionURL: String, request: RTSPRequest, encryptionKey: Data?) async throws -> RTSPResponse {
        _ = sessionURL
        requests.append(request)
        encryptionKeys.append(encryptionKey)
        guard index < responses.count else {
            throw MoonlightError(.unsupportedOperation, message: "No more RTSP fixture responses available")
        }
        defer { index += 1 }
        return responses[index]
    }

    public func recordedRequests() -> [RTSPRequest] {
        requests
    }

    public func recordedEncryptionKeys() -> [Data?] {
        encryptionKeys
    }
}

public actor RecordingChannelTransport: ChannelTransport {
    private var requests: [(hostID: HostID, descriptor: ChannelDescriptor)] = []

    public init() {}

    public func establishChannel(
        to host: MoonlightHost,
        descriptor: ChannelDescriptor
    ) async throws -> EstablishedChannel {
        requests.append((host.id, descriptor))
        return EstablishedChannel(descriptor: descriptor, isConnected: true)
    }

    public func recordedRequests() -> [(hostID: HostID, descriptor: ChannelDescriptor)] {
        requests
    }
}

public actor RecordingControlChannelTransport: ControlChannelTransport {
    private var sentPackets: [(packet: Data, channelID: UInt8, reliable: Bool)] = []
    private var receivedPackets: [Data]

    public init(receivedPackets: [Data] = []) {
        self.receivedPackets = receivedPackets
    }

    public func send(packet: Data, channelID: UInt8, reliable: Bool) async throws {
        sentPackets.append((packet, channelID, reliable))
    }

    public func receivePacket() async throws -> Data? {
        guard !receivedPackets.isEmpty else {
            return nil
        }

        return receivedPackets.removeFirst()
    }

    public func recordedSentPackets() -> [(packet: Data, channelID: UInt8, reliable: Bool)] {
        sentPackets
    }
}

public actor RecordingMetricsControlChannelTransport: ControlChannelTransport, ControlTransportMetricsReporting {
    private var sentPackets: [(packet: Data, channelID: UInt8, reliable: Bool)] = []
    private var receivedPackets: [Data]
    private var metrics: ControlTransportMetricsSnapshot

    public init(
        receivedPackets: [Data] = [],
        metrics: ControlTransportMetricsSnapshot = .init()
    ) {
        self.receivedPackets = receivedPackets
        self.metrics = metrics
    }

    public func send(packet: Data, channelID: UInt8, reliable: Bool) async throws {
        sentPackets.append((packet, channelID, reliable))
    }

    public func receivePacket() async throws -> Data? {
        guard !receivedPackets.isEmpty else {
            return nil
        }

        return receivedPackets.removeFirst()
    }

    public func snapshotControlTransportMetrics() async -> ControlTransportMetricsSnapshot {
        metrics
    }

    public func updateMetrics(_ metrics: ControlTransportMetricsSnapshot) {
        self.metrics = metrics
    }

    public func recordedSentPackets() -> [(packet: Data, channelID: UInt8, reliable: Bool)] {
        sentPackets
    }
}

public actor FlakyControlChannelTransport: ControlChannelTransport {
    public enum Step: Sendable {
        case packet(Data)
        case failure(MoonlightError)
        case end
    }

    private var steps: [Step]
    private var sentPackets: [(packet: Data, channelID: UInt8, reliable: Bool)] = []

    public init(steps: [Step]) {
        self.steps = steps
    }

    public func send(packet: Data, channelID: UInt8, reliable: Bool) async throws {
        sentPackets.append((packet, channelID, reliable))
    }

    public func receivePacket() async throws -> Data? {
        guard !steps.isEmpty else {
            return nil
        }

        switch steps.removeFirst() {
        case .packet(let packet):
            return packet
        case .failure(let error):
            throw error
        case .end:
            return nil
        }
    }

    public func recordedSentPackets() -> [(packet: Data, channelID: UInt8, reliable: Bool)] {
        sentPackets
    }
}

public actor FixtureMediaPacketSource: MediaPacketSource {
    private var packets: [Data]

    public init(packets: [Data] = []) {
        self.packets = packets
    }

    public func receivePacket() async throws -> Data? {
        guard !packets.isEmpty else {
            return nil
        }
        return packets.removeFirst()
    }
}

public actor FlakyMediaPacketSource: MediaPacketSource {
    public enum Step: Sendable {
        case packet(Data)
        case failure(MoonlightError)
        case end
    }

    private var steps: [Step]

    public init(steps: [Step]) {
        self.steps = steps
    }

    public func receivePacket() async throws -> Data? {
        guard !steps.isEmpty else {
            return nil
        }

        switch steps.removeFirst() {
        case .packet(let packet):
            return packet
        case .failure(let error):
            throw error
        case .end:
            return nil
        }
    }
}
