import CENet
import Foundation

private enum ENetControlConstants {
    static let channelCount = Int(ControlChannelID.count)
    static let connectTimeoutMs: UInt32 = 10_000
    static let servicePollMs: UInt32 = 5
    static let receiveIdleSleep: Duration = .milliseconds(1)
    static let periodicPingInterval: Duration = .milliseconds(100)
    static let startAPlainType: UInt16 = 0x0305
    static let startAEncryptedType: UInt16 = 0x0302
    static let startBType: UInt16 = 0x0307
    static let periodicPingType: UInt16 = 0x0200
    static let inputPacketType: UInt16 = 0x0206
}

private enum ENetReceiveResult {
    case packet(Data)
    case none
    case disconnected
}

private enum ENetLibraryState {
    static let initializeResult: Int32 = enet_initialize()
}

private func ensureENetInitialized() throws {
    guard ENetLibraryState.initializeResult == 0 else {
        throw MoonlightError(.unsupportedOperation, message: "Failed to initialize ENet")
    }
}

private final class ENetControlSessionCore: @unchecked Sendable {
    private let lock = NSLock()
    private let crypto = ControlPacketCrypto()
    private var host: UnsafeMutablePointer<ENetHost>?
    private var peer: UnsafeMutablePointer<ENetPeer>?
    private var nextSequenceNumber: UInt32 = 0
    private var closed = false

    init(
        remoteHost: String,
        remotePort: UInt16,
        connectData: UInt32,
        controlEncryption: ControlEncryptionContext?
    ) throws {
        try ensureENetInitialized()

        let host = enet_host_create(nil, 1, ENetControlConstants.channelCount, 0, 0)
        guard let host else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to create ENet host")
        }

        self.host = host

        var address = ENetAddress()
        address.port = remotePort
        let resolveResult = remoteHost.withCString { enet_address_set_host(&address, $0) }
        guard resolveResult == 0 else {
            destroyLockedResources()
            throw MoonlightError(.unsupportedOperation, message: "Failed to resolve ENet host \(remoteHost)")
        }

        guard let peer = enet_host_connect(host, &address, ENetControlConstants.channelCount, connectData) else {
            destroyLockedResources()
            throw MoonlightError(.unsupportedOperation, message: "Failed to create ENet peer")
        }

        self.peer = peer
        enet_peer_timeout(peer, 2, 10_000, 10_000)

        try waitForConnect()
        try sendStartupHandshake(controlEncryption: controlEncryption)
    }

    deinit {
        close()
    }

    func send(packet: Data, channelID: UInt8, reliable: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        try sendLocked(packet: packet, channelID: channelID, reliable: reliable)
    }

    func sendControlPayload(
        packetType: UInt16,
        payload: Data,
        channelID: UInt8,
        reliable: Bool,
        encryption: ControlEncryptionContext?
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        let packet = try makeControlPacketLocked(
            packetType: packetType,
            payload: payload,
            encryption: encryption
        )
        try sendLocked(packet: packet, channelID: channelID, reliable: reliable)
    }

    func sendInputPacket(
        payload: Data,
        channelID: UInt8,
        reliable: Bool,
        encryption: ControlEncryptionContext?
    ) throws {
        try sendControlPayload(
            packetType: ENetControlConstants.inputPacketType,
            payload: payload,
            channelID: channelID,
            reliable: reliable,
            encryption: encryption
        )
    }

    func receivePacket(timeoutMs: UInt32) throws -> ENetReceiveResult {
        lock.lock()
        defer { lock.unlock() }

        guard let host else {
            return .disconnected
        }

        var event = ENetEvent()
        let serviceResult = enet_host_service(host, &event, timeoutMs)
        if serviceResult < 0 {
            throw MoonlightError(.unsupportedOperation, message: "ENet control service failed")
        }
        if serviceResult == 0 {
            return .none
        }

        switch event.type {
        case ENET_EVENT_TYPE_RECEIVE:
            guard let packet = event.packet else {
                return .none
            }
            defer { enet_packet_destroy(packet) }
            let data = Data(bytes: packet.pointee.data, count: packet.pointee.dataLength)
            return .packet(data)

        case ENET_EVENT_TYPE_DISCONNECT:
            return .disconnected

        case ENET_EVENT_TYPE_CONNECT:
            return .none

        default:
            return .none
        }
    }

    func localPort() throws -> UInt16 {
        lock.lock()
        defer { lock.unlock() }

        guard let host else {
            throw MoonlightError(.unsupportedOperation, message: "ENet host is closed")
        }

        var address = ENetAddress()
        let result = enet_socket_get_address(host.pointee.socket, &address)
        guard result == 0 else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to query ENet local port")
        }
        return address.port
    }

    func snapshotControlTransportMetrics() -> ControlTransportMetricsSnapshot {
        lock.lock()
        defer { lock.unlock() }

        guard let peer else {
            return ControlTransportMetricsSnapshot(isConnected: false)
        }

        let isConnected = peer.pointee.state == ENET_PEER_STATE_CONNECTED
        guard isConnected else {
            return ControlTransportMetricsSnapshot(isConnected: false)
        }

        let lossScale = Double(ENET_PEER_PACKET_LOSS_SCALE)
        return ControlTransportMetricsSnapshot(
            isConnected: true,
            roundTripTimeMs: Int(peer.pointee.roundTripTime),
            roundTripTimeVarianceMs: Int(peer.pointee.roundTripTimeVariance),
            packetLossRatio: Double(peer.pointee.packetLoss) / lossScale,
            packetLossVarianceRatio: Double(peer.pointee.packetLossVariance) / lossScale
        )
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        destroyLockedResources()
    }

    private func waitForConnect() throws {
        guard let host, let peer else {
            throw MoonlightError(.unsupportedOperation, message: "ENet host is unavailable")
        }

        let deadline = Date().timeIntervalSince1970 + Double(ENetControlConstants.connectTimeoutMs) / 1000
        while Date().timeIntervalSince1970 < deadline {
            var event = ENetEvent()
            let serviceResult = enet_host_service(host, &event, ENetControlConstants.servicePollMs)
            if serviceResult < 0 {
                throw MoonlightError(.unsupportedOperation, message: "ENet connect failed while servicing host")
            }
            if serviceResult == 0 {
                continue
            }

            switch event.type {
            case ENET_EVENT_TYPE_CONNECT:
                enet_host_flush(host)
                return
            case ENET_EVENT_TYPE_RECEIVE:
                if let packet = event.packet {
                    enet_packet_destroy(packet)
                }
            case ENET_EVENT_TYPE_DISCONNECT:
                throw MoonlightError(.unsupportedOperation, message: "ENet control peer disconnected during connect")
            default:
                break
            }
        }

        enet_peer_disconnect_now(peer, 0)
        throw MoonlightError(.unsupportedOperation, message: "Timed out connecting ENet control stream")
    }

    private func sendStartupHandshake(controlEncryption: ControlEncryptionContext?) throws {
        let startAType = if controlEncryption != nil {
            ENetControlConstants.startAEncryptedType
        } else {
            ENetControlConstants.startAPlainType
        }
        try sendControlPayload(
            packetType: startAType,
            payload: Data([0x00, 0x00]),
            channelID: ControlChannelID.generic,
            reliable: true,
            encryption: controlEncryption
        )
        try sendControlPayload(
            packetType: ENetControlConstants.startBType,
            payload: Data([0x00]),
            channelID: ControlChannelID.generic,
            reliable: true,
            encryption: controlEncryption
        )
    }

    private func sendLocked(packet: Data, channelID: UInt8, reliable: Bool) throws {
        guard let host, let peer else {
            throw MoonlightError(.unsupportedOperation, message: "ENet control peer is unavailable")
        }

        let flags: enet_uint32 = reliable ? UInt32(ENET_PACKET_FLAG_RELIABLE.rawValue) : 0
        let enetPacket = packet.withUnsafeBytes { bytes in
            enet_packet_create(bytes.baseAddress, packet.count, flags)
        }
        guard let enetPacket else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to allocate ENet packet")
        }

        let effectiveChannelID: UInt8
        if channelID < peer.pointee.channelCount {
            effectiveChannelID = channelID
        } else {
            effectiveChannelID = ControlChannelID.generic
        }

        let sendResult = enet_peer_send(peer, effectiveChannelID, enetPacket)
        if sendResult != 0 {
            enet_packet_destroy(enetPacket)
            throw MoonlightError(
                .unsupportedOperation,
                message: "Failed to queue ENet control packet (result=\(sendResult), peerState=\(peer.pointee.state.rawValue), channel=\(effectiveChannelID), peerChannels=\(peer.pointee.channelCount))"
            )
        }

        _ = enet_host_service(host, nil, 0)
        enet_host_flush(host)
    }

    private func makeControlPacketLocked(
        packetType: UInt16,
        payload: Data,
        encryption: ControlEncryptionContext?
    ) throws -> Data {
        guard let encryption else {
            return makePlainControlPacket(packetType: packetType, payload: payload)
        }

        let sequenceNumber = nextSequenceNumber
        nextSequenceNumber &+= 1
        return try crypto.seal(
            packetType: packetType,
            payload: payload,
            sequenceNumber: sequenceNumber,
            sender: .client,
            context: encryption
        )
    }

    private func destroyLockedResources() {
        guard !closed else {
            return
        }
        closed = true

        if let peer {
            enet_peer_disconnect_now(peer, 0)
            self.peer = nil
        }

        if let host {
            enet_host_destroy(host)
            self.host = nil
        }
    }

    private func makePlainControlPacket(packetType: UInt16, payload: Data) -> Data {
        var packet = Data()
        packet.appendLE(packetType)
        packet.append(payload)
        return packet
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 0))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 0))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}

public final class ENetControlSession: @unchecked Sendable {
    fileprivate let core: ENetControlSessionCore
    public let controlEncryption: ControlEncryptionContext?
    private let periodicPingTask: Task<Void, Never>

    public init(
        remoteHost: String,
        remotePort: UInt16,
        connectData: UInt32,
        controlEncryption: ControlEncryptionContext?
    ) throws {
        self.controlEncryption = controlEncryption
        self.core = try ENetControlSessionCore(
            remoteHost: remoteHost,
            remotePort: remotePort,
            connectData: connectData,
            controlEncryption: controlEncryption
        )
        periodicPingTask = Task { [core, controlEncryption] in
            while !Task.isCancelled {
                do {
                    try core.sendControlPayload(
                        packetType: ENetControlConstants.periodicPingType,
                        payload: Self.makePeriodicPingPayload(),
                        channelID: ControlChannelID.generic,
                        reliable: Self.periodicPingUsesReliableDelivery,
                        encryption: controlEncryption
                    )
                } catch {
                    // Transient send failures are expected during ENet startup and
                    // lock contention with the receive loop.
                }

                do {
                    try await Task.sleep(for: ENetControlConstants.periodicPingInterval)
                } catch {
                    return
                }
            }
        }
    }

    deinit {
        close()
    }

    public func close() {
        periodicPingTask.cancel()
        core.close()
    }

    static var periodicPingUsesReliableDelivery: Bool {
        true
    }

    static func makePeriodicPingPayload() -> Data {
        var payload = Data(capacity: 8)
        payload.appendLE(UInt16(4))
        payload.appendLE(UInt32(0))
        payload.append(contentsOf: [0x00, 0x00])
        return payload
    }
}

public actor ENetControlChannelTransport: TypedControlPacketTransport, ControlTransportMetricsReporting, LocalPortReporting, ClosableTransport {
    private let session: ENetControlSession

    public init(session: ENetControlSession) {
        self.session = session
    }

    public func send(packet: Data, channelID: UInt8, reliable: Bool) async throws {
        try session.core.send(packet: packet, channelID: channelID, reliable: reliable)
    }

    public func sendControlPayload(
        packetType: UInt16,
        payload: Data,
        channelID: UInt8,
        reliable: Bool,
        encryption: ControlEncryptionContext?
    ) async throws {
        try session.core.sendControlPayload(
            packetType: packetType,
            payload: payload,
            channelID: channelID,
            reliable: reliable,
            encryption: encryption
        )
    }

    public func receivePacket() async throws -> Data? {
        while !Task.isCancelled {
            switch try session.core.receivePacket(timeoutMs: 0) {
            case .packet(let packet):
                return packet
            case .none:
                do {
                    try await Task.sleep(for: ENetControlConstants.receiveIdleSleep)
                } catch {
                    return nil
                }
                continue
            case .disconnected:
                return nil
            }
        }

        return nil
    }

    public func localPort() async throws -> UInt16 {
        try session.core.localPort()
    }

    public func snapshotControlTransportMetrics() async -> ControlTransportMetricsSnapshot {
        session.core.snapshotControlTransportMetrics()
    }

    public func close() async {
        session.close()
    }
}

public actor ENetInputPacketTransport: InputPacketTransport, LocalPortReporting, ClosableTransport {
    private let session: ENetControlSession

    public init(session: ENetControlSession) {
        self.session = session
    }

    public func send(_ packet: Data, channelID: UInt8, reliable: Bool) async throws {
        try session.core.sendInputPacket(
            payload: packet,
            channelID: channelID,
            reliable: reliable,
            encryption: session.controlEncryption
        )
    }

    public func localPort() async throws -> UInt16 {
        try session.core.localPort()
    }

    public func close() async {
        session.close()
    }
}
