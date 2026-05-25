import Foundation

public actor UDPControlChannelTransport: ControlChannelTransport, LocalPortReporting, ClosableTransport {
    private let socket: ConnectedUDPSocket

    public init(socket: ConnectedUDPSocket) {
        self.socket = socket
    }

    public func send(packet: Data, channelID: UInt8, reliable: Bool) async throws {
        _ = channelID
        _ = reliable
        try await socket.send(packet)
    }

    public func receivePacket() async throws -> Data? {
        try await socket.receivePacket()
    }

    public func localPort() async throws -> UInt16 {
        try await socket.localPort()
    }

    public func close() async {
        await socket.close()
    }
}

public actor UDPInputPacketTransport: InputPacketTransport, LocalPortReporting, ClosableTransport {
    private let socket: ConnectedUDPSocket

    public init(socket: ConnectedUDPSocket) {
        self.socket = socket
    }

    public func send(_ packet: Data, channelID: UInt8, reliable: Bool) async throws {
        _ = channelID
        _ = reliable
        try await socket.send(packet)
    }

    public func localPort() async throws -> UInt16 {
        try await socket.localPort()
    }

    public func close() async {
        await socket.close()
    }
}

public actor UDPChannelPacketSource: MediaKeepaliveSource, LocalPortReporting, ClosableTransport {
    private let socket: BoundUDPSocket
    private let keepalivePacketGenerator: MediaKeepalivePacketGenerator?
    private let keepalive: PeriodicSocketPacketSender?
    public init(
        socket: BoundUDPSocket,
        keepalivePacket: Data? = nil,
        keepaliveInterval: Duration = .milliseconds(500)
    ) {
        self.socket = socket
        if let keepalivePacket {
            let generator = MediaKeepalivePacketGenerator(template: keepalivePacket)
            keepalivePacketGenerator = generator
            keepalive = PeriodicSocketPacketSender(
                send: { packet in
                    try await socket.send(packet)
                },
                packetProvider: {
                    await generator.nextPacket()
                },
                burstCount: 5,
                burstInterval: .milliseconds(100),
                interval: keepaliveInterval
            )
        } else {
            keepalivePacketGenerator = nil
            keepalive = nil
        }
    }

    public func receivePacket() async throws -> Data? {
        try await socket.receivePacket()
    }

    public func localPort() async throws -> UInt16 {
        try await socket.localPort()
    }

    public func sendKeepaliveNow() async throws {
        guard let keepalivePacketGenerator else {
            return
        }
        try await socket.send(await keepalivePacketGenerator.nextPacket())
    }

    public func close() async {
        await socket.close()
    }
}

private actor MediaKeepalivePacketGenerator {
    private static let sunshinePingSize = 20
    private let template: Data
    private var sequenceNumber: UInt32 = 0

    init(template: Data) {
        self.template = template
    }

    func nextPacket() -> Data {
        guard template.count == Self.sunshinePingSize else {
            return template
        }

        sequenceNumber &+= 1
        var packet = template
        let value = sequenceNumber.bigEndian
        withUnsafeBytes(of: value) { bytes in
            packet.replaceSubrange(16..<20, with: bytes)
        }
        return packet
    }
}

private final class PeriodicSocketPacketSender: @unchecked Sendable {
    private let task: Task<Void, Never>

    init(
        send: @escaping @Sendable (Data) async throws -> Void,
        packetProvider: @escaping @Sendable () async -> Data,
        burstCount: Int = 0,
        burstInterval: Duration = .milliseconds(100),
        interval: Duration
    ) {
        task = Task {
            // Send an initial rapid burst to ensure the host receives at least one ping
            // before its recv_ping timeout expires, even if the first few are lost.
            for _ in 0..<burstCount {
                guard !Task.isCancelled else { return }
                try? await send(await packetProvider())
                do { try await Task.sleep(for: burstInterval) } catch { return }
            }

            while !Task.isCancelled {
                do {
                    try await send(await packetProvider())
                } catch {
                    // Sunshine/Apollo sessions can race with host-side UDP bind setup.
                    // Real Moonlight clients keep pinging through early ICMP/socket errors.
                }

                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
            }
        }
    }

    deinit {
        task.cancel()
    }
}

public struct ChannelSocketSet: Sendable {
    public var controlTransport: (any ControlChannelTransport & LocalPortReporting & ClosableTransport)?
    public var inputTransport: (any InputPacketTransport & LocalPortReporting & ClosableTransport)?
    public var videoSource: (any MediaKeepaliveSource & LocalPortReporting & ClosableTransport)?
    public var audioSource: (any MediaKeepaliveSource & LocalPortReporting & ClosableTransport)?

    public init(
        controlTransport: (any ControlChannelTransport & LocalPortReporting & ClosableTransport)? = nil,
        inputTransport: (any InputPacketTransport & LocalPortReporting & ClosableTransport)? = nil,
        videoSource: (any MediaKeepaliveSource & LocalPortReporting & ClosableTransport)? = nil,
        audioSource: (any MediaKeepaliveSource & LocalPortReporting & ClosableTransport)? = nil
    ) {
        self.controlTransport = controlTransport
        self.inputTransport = inputTransport
        self.videoSource = videoSource
        self.audioSource = audioSource
    }

    public func close() async {
        await controlTransport?.close()
        await inputTransport?.close()
        await videoSource?.close()
        await audioSource?.close()
    }
}

public struct ChannelSocketFactory: Sendable {
    public let probeBuilder: ChannelProbeBuilder

    public init(probeBuilder: ChannelProbeBuilder = .init()) {
        self.probeBuilder = probeBuilder
    }

    public func makeSockets(
        for host: MoonlightHost,
        controlEncryption: ControlEncryptionContext? = nil,
        includeControlTransports: Bool = true,
        negotiatedSession: NegotiatedSession
    ) throws -> ChannelSocketSet {
        try makeSockets(
            for: host,
            channels: negotiatedSession.channels,
            controlEncryption: controlEncryption,
            includeControlTransports: includeControlTransports
        )
    }

    public func makeSockets(
        for host: MoonlightHost,
        channels: [EstablishedChannel],
        controlEncryption: ControlEncryptionContext? = nil,
        includeControlTransports: Bool = true
    ) throws -> ChannelSocketSet {
        var sockets = ChannelSocketSet()
        let enetConnectData = channels
            .first(where: { $0.isConnected && $0.descriptor.kind == .control })?
            .descriptor
            .metadata["connectData"]
            .flatMap(UInt32.init)

        if includeControlTransports,
           let enetConnectData,
           let controlChannel = channels.first(where: { $0.isConnected && $0.descriptor.kind == .control })
        {
            let transportPair = try makeENetControlTransports(
                host: host,
                port: controlChannel.descriptor.port,
                connectData: enetConnectData,
                controlEncryption: controlEncryption
            )
            sockets.controlTransport = transportPair.control
            sockets.inputTransport = transportPair.input
        }

        for channel in channels where channel.isConnected {
            if !includeControlTransports,
               channel.descriptor.kind == .control || channel.descriptor.kind == .input
            {
                continue
            }

            if includeControlTransports,
               enetConnectData != nil,
               channel.descriptor.kind == .control || channel.descriptor.kind == .input
            {
                continue
            }

            let localPort = channel.descriptor.metadata["localPort"].flatMap(UInt16.init)

            switch channel.descriptor.kind {
            case .control:
                let socket = try ConnectedUDPSocket(
                    remoteHost: host.endpoint.address,
                    remotePort: channel.descriptor.port,
                    localPort: localPort ?? 0
                )
                sockets.controlTransport = UDPControlChannelTransport(socket: socket)
            case .input:
                let socket = try ConnectedUDPSocket(
                    remoteHost: host.endpoint.address,
                    remotePort: channel.descriptor.port,
                    localPort: localPort ?? 0
                )
                sockets.inputTransport = UDPInputPacketTransport(socket: socket)
            case .video:
                let socket = try BoundUDPSocket(
                    remoteHost: host.endpoint.address,
                    remotePort: channel.descriptor.port,
                    localPort: localPort ?? 0
                )
                sockets.videoSource = UDPChannelPacketSource(
                    socket: socket,
                    keepalivePacket: try probeBuilder.makeProbe(for: channel.descriptor)
                )
            case .audio:
                let socket = try BoundUDPSocket(
                    remoteHost: host.endpoint.address,
                    remotePort: channel.descriptor.port,
                    localPort: localPort ?? 0
                )
                sockets.audioSource = UDPChannelPacketSource(
                    socket: socket,
                    keepalivePacket: try probeBuilder.makeProbe(for: channel.descriptor)
                )
            }
        }

        return sockets
    }

    public func makeAndPrimeSockets(
        for host: MoonlightHost,
        controlEncryption: ControlEncryptionContext? = nil,
        includeControlTransports: Bool = true,
        negotiatedSession: NegotiatedSession
    ) async throws -> ChannelSocketSet {
        try await makeAndPrimeSockets(
            for: host,
            channels: negotiatedSession.channels,
            controlEncryption: controlEncryption,
            includeControlTransports: includeControlTransports
        )
    }

    public func makeAndPrimeSockets(
        for host: MoonlightHost,
        channels: [EstablishedChannel],
        controlEncryption: ControlEncryptionContext? = nil,
        includeControlTransports: Bool = true
    ) async throws -> ChannelSocketSet {
        let sockets = try makeSockets(
            for: host,
            channels: channels,
            controlEncryption: controlEncryption,
            includeControlTransports: includeControlTransports
        )
        try? await sockets.videoSource?.sendKeepaliveNow()
        try? await sockets.audioSource?.sendKeepaliveNow()
        return sockets
    }

    private func makeENetControlTransports(
        host: MoonlightHost,
        port: UInt16,
        connectData: UInt32,
        controlEncryption: ControlEncryptionContext?
    ) throws -> (
        control: any ControlChannelTransport & LocalPortReporting & ClosableTransport,
        input: any InputPacketTransport & LocalPortReporting & ClosableTransport
    ) {
        let session = try ENetControlSession(
            remoteHost: host.endpoint.address,
            remotePort: port,
            connectData: connectData,
            controlEncryption: controlEncryption
        )
        return (
            control: ENetControlChannelTransport(session: session),
            input: ENetInputPacketTransport(session: session)
        )
    }
}
