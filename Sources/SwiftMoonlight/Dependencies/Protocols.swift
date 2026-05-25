import Foundation

public protocol Clock: Sendable {
    func now() -> Date
}

public protocol HostStore: Sendable {
    func loadHosts() async throws -> [MoonlightHost]
    func saveHosts(_ hosts: [MoonlightHost]) async throws
}

public protocol HostDiscovery: Sendable {
    func discover(timeout: Duration) async throws -> [DiscoveredHost]
}

public protocol IdentityStore: Sendable {
    func loadOrCreateIdentity() async throws -> ClientIdentity
    func clearIdentity() async throws
}

public protocol MoonlightLogger: Sendable {
    func debug(_ message: String)
    func info(_ message: String)
    func warning(_ message: String)
    func error(_ message: String)
}

public protocol MetricsSink: Sendable {
    func record(_ snapshot: SessionMetricsSnapshot) async
}

public protocol HostService: Sendable {
    func fetchServerInfo(for host: MoonlightHost) async throws -> Data
    func fetchAppList(for host: MoonlightHost) async throws -> Data
    func cancelCurrentApp(for host: MoonlightHost) async throws
}

public protocol SessionService: Sendable {
    func launchSession(
        for host: MoonlightHost,
        appID: RemoteApp.ID,
        configuration: StreamConfiguration,
        identity: ClientIdentity
    ) async throws -> NegotiatedSession
}

public protocol SessionLaunchTransport: Sendable {
    func sendLaunchRequest(
        to host: MoonlightHost,
        queryItems: [URLQueryItem]
    ) async throws -> Data
}

public protocol HTTPClient: Sendable {
    func get(url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse)
}

public protocol PairingTransport: Sendable {
    func sendPairingRequest(
        to host: MoonlightHost,
        queryItems: [URLQueryItem]
    ) async throws -> Data

    func sendUnpairRequest(
        to host: MoonlightHost,
        queryItems: [URLQueryItem]
    ) async throws -> Data
}

public protocol PairingClientService: Sendable {
    func pair(host: MoonlightHost, auth: PairingAuth, identity: ClientIdentity) async throws -> PairingResult
    func unpair(host: MoonlightHost, identity: ClientIdentity) async throws
}

public extension PairingClientService {
    func pair(host: MoonlightHost, pin: String, identity: ClientIdentity) async throws -> PairingResult {
        try await pair(host: host, auth: .pin(pin), identity: identity)
    }
}

public protocol RTSPTransport: Sendable {
    func transact(sessionURL: String, request: RTSPRequest, encryptionKey: Data?) async throws -> RTSPResponse
}

public protocol ChannelTransport: Sendable {
    func establishChannel(
        to host: MoonlightHost,
        descriptor: ChannelDescriptor
    ) async throws -> EstablishedChannel
}

public protocol ControlChannelTransport: Sendable {
    func send(packet: Data, channelID: UInt8, reliable: Bool) async throws
    func receivePacket() async throws -> Data?
}

public protocol ControlTransportMetricsReporting: Sendable {
    func snapshotControlTransportMetrics() async -> ControlTransportMetricsSnapshot
}

public protocol TypedControlPacketTransport: ControlChannelTransport {
    func sendControlPayload(
        packetType: UInt16,
        payload: Data,
        channelID: UInt8,
        reliable: Bool,
        encryption: ControlEncryptionContext?
    ) async throws
}

public protocol LocalPortReporting: Sendable {
    func localPort() async throws -> UInt16
}

public protocol ClosableTransport: Sendable {
    func close() async
}

public protocol MediaPacketSource: Sendable {
    func receivePacket() async throws -> Data?
}

public protocol MediaKeepaliveSource: MediaPacketSource {
    func sendKeepaliveNow() async throws
}

public struct BootstrappedSession: Sendable {
    public var negotiatedSession: NegotiatedSession
    public var primedSockets: ChannelSocketSet?

    public init(negotiatedSession: NegotiatedSession, primedSockets: ChannelSocketSet? = nil) {
        self.negotiatedSession = negotiatedSession
        self.primedSockets = primedSockets
    }
}

public protocol SessionBootstrapService: Sendable {
    func openSession(
        host: MoonlightHost,
        appID: RemoteApp.ID,
        configuration: StreamConfiguration,
        identity: ClientIdentity
    ) async throws -> BootstrappedSession
}
