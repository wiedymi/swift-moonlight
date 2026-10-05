import Foundation
import SwiftENet

public final class ENetControlSession: Sendable {
    fileprivate let connection: ENetConnection
    public var controlEncryption: ControlEncryptionContext? { connection.encryption }

    public init(remoteHost: String, remotePort: UInt16, connectData: UInt32,
                controlEncryption: ControlEncryptionContext?) async throws {
        let client: Client
        do { client = try await Client.connect(host: remoteHost, port: remotePort, connectData: connectData) }
        catch { throw transportError(error) }
        connection = ENetConnection(client: client, encryption: controlEncryption)
        do { try await connection.start() }
        catch { await connection.close(); throw transportError(error) }
    }

    deinit {
        let connection = connection
        Task { await connection.close() }
    }

    public func close() async { await connection.close() }
    static var periodicPingUsesReliableDelivery: Bool { true }
    static func makePeriodicPingPayload() -> Data { Data([4, 0, 0, 0, 0, 0, 0, 0]) }
}

fileprivate actor ENetConnection {
    private let client: Client
    nonisolated let encryption: ControlEncryptionContext?
    nonisolated var unownedExecutor: UnownedSerialExecutor { client.unownedExecutor }
    private let crypto = ControlPacketCrypto()
    private var encryptionSequence: UInt64 = 0
    private var pingTask: Task<Void, Never>?

    init(client: Client, encryption: ControlEncryptionContext?) {
        self.client = client; self.encryption = encryption
    }

    func start() async throws {
        let type: UInt16 = encryption == nil ? 0x0305 : 0x0302
        try await sendPayload(type: type, payload: Data([0, 0]), channel: 0, reliable: true, encryption: encryption)
        try await sendPayload(type: 0x0307, payload: Data([0]), channel: 0, reliable: true, encryption: encryption)
        try await sendPing()
        // One task lives for the session. SwiftENet independently owns its
        // native retry timer; no per-packet sleep task is created here.
        pingTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(100))
                    guard let self else { return }
                    try await self.sendPing()
                }
            } catch is CancellationError { }
            catch { await self?.close(error: error) }
        }
    }

    private func sendPing() async throws {
        try await sendPayload(type: 0x0200, payload: ENetControlSession.makePeriodicPingPayload(),
                              channel: 0, reliable: true, encryption: encryption)
    }

    func send(_ packet: Data, channel: UInt8, reliable: Bool) async throws {
        // The Moonlight fork can negotiate one channel. Keep its established
        // channel-zero fallback here, rather than in the general ENet API.
        let selected = Int(channel) < (await client.channelCount) ? channel : 0
        try await client.send(packet, channelID: selected, delivery: reliable ? .reliable : .unreliable)
    }

    func sendPayload(type: UInt16, payload: Data, channel: UInt8, reliable: Bool,
                     encryption: ControlEncryptionContext?) async throws {
        let packet: Data
        if let encryption {
            guard payload.count <= 65_511, encryptionSequence <= UInt64(UInt32.max) else {
                throw ClientError.messageTooLarge
            }
            packet = try crypto.seal(packetType: type, payload: payload, sequenceNumber: UInt32(encryptionSequence),
                                     sender: .client, context: encryption)
            encryptionSequence += 1
        } else {
            guard payload.count <= Client.maximumMessageSize - 2 else { throw ClientError.messageTooLarge }
            var plain = Data([UInt8(truncatingIfNeeded: type), UInt8(truncatingIfNeeded: type >> 8)])
            plain.append(payload); packet = plain
        }
        try await send(packet, channel: channel, reliable: reliable)
    }

    func receivePacket() async throws -> Data? { try await client.receivePacket()?.data }
    func localPort() -> UInt16 { client.localPort }
    func metrics() async -> ControlTransportMetricsSnapshot {
        let metrics = await client.snapshotMetrics()
        return .init(isConnected: metrics.isConnected, roundTripTimeMs: metrics.roundTripTimeMs,
                     roundTripTimeVarianceMs: metrics.roundTripTimeVarianceMs,
                     packetLossRatio: metrics.packetLossRatio, packetLossVarianceRatio: metrics.packetLossVarianceRatio,
                     queuedSendBytes: metrics.queuedSendBytes, inFlightSendBytes: metrics.inFlightSendBytes,
                     discardedSocketDatagrams: metrics.discardedSocketDatagrams)
    }
    func close(error: (any Error)? = nil) async { pingTask?.cancel(); pingTask = nil; await client.close(throwing: error) }
}

public actor ENetControlChannelTransport: TypedControlPacketTransport, ControlTransportMetricsReporting, LocalPortReporting, ClosableTransport {
    private let session: ENetControlSession
    public nonisolated var unownedExecutor: UnownedSerialExecutor { session.connection.unownedExecutor }
    public init(session: ENetControlSession) { self.session = session }
    public func send(packet: Data, channelID: UInt8, reliable: Bool) async throws {
        do { try await session.connection.send(packet, channel: channelID, reliable: reliable) }
        catch { throw transportError(error) }
    }
    public func sendControlPayload(packetType: UInt16, payload: Data, channelID: UInt8, reliable: Bool,
                                   encryption: ControlEncryptionContext?) async throws {
        do {
            try await session.connection.sendPayload(type: packetType, payload: payload, channel: channelID,
                                                      reliable: reliable, encryption: encryption)
        } catch { throw transportError(error) }
    }
    public func receivePacket() async throws -> Data? {
        do { return try await session.connection.receivePacket() }
        catch { throw transportError(error) }
    }
    public func localPort() async throws -> UInt16 { await session.connection.localPort() }
    public func snapshotControlTransportMetrics() async -> ControlTransportMetricsSnapshot { await session.connection.metrics() }
    public func close() async { await session.close() }
}

public actor ENetInputPacketTransport: InputPacketTransport, LocalPortReporting, ClosableTransport {
    private let session: ENetControlSession
    public nonisolated var unownedExecutor: UnownedSerialExecutor { session.connection.unownedExecutor }
    public init(session: ENetControlSession) { self.session = session }
    public func send(_ packet: Data, channelID: UInt8, reliable: Bool) async throws {
        do {
            try await session.connection.sendPayload(type: 0x0206, payload: packet, channel: channelID,
                                                      reliable: reliable, encryption: session.controlEncryption)
        } catch { throw transportError(error) }
    }
    public func localPort() async throws -> UInt16 { await session.connection.localPort() }
    public func close() async { await session.close() }
}

private func transportError(_ error: any Error) -> any Error {
    guard let error = error as? ClientError else { return error }
    switch error {
    case .invalidPacket: return MoonlightError(.invalidControlMessage, message: "Invalid ENet packet")
    case .invalidConnect: return MoonlightError(.networkRequestFailed, message: "ENet connection setup failed")
    case .timedOut: return MoonlightError(.networkRequestFailed, message: "ENet connection timed out")
    case .notConnected, .closed: return MoonlightError(.invalidStateTransition, message: "ENet connection is closed")
    case .queueFull: return MoonlightError(.unsupportedOperation, message: "ENet queue limit exceeded")
    case .invalidChannel: return MoonlightError(.unsupportedOperation, message: "Invalid ENet channel")
    case .packetReaderInUse: return MoonlightError(.invalidStateTransition, message: "ENet permits one packet reader")
    case .socketFailure: return MoonlightError(.networkRequestFailed, message: "ENet socket failed")
    case .messageTooLarge: return MoonlightError(.unsupportedOperation, message: "ENet message size or sequence limit exceeded")
    }
}
