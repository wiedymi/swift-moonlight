import Foundation

public struct UDPChannelTransport: ChannelTransport {
    public let socketFactory: @Sendable (_ remoteHost: String, _ remotePort: UInt16) throws -> ConnectedUDPSocket
    public let probeBuilder: ChannelProbeBuilder

    public init(
        socketFactory: @escaping @Sendable (_ remoteHost: String, _ remotePort: UInt16) throws -> ConnectedUDPSocket = {
            try ConnectedUDPSocket(remoteHost: $0, remotePort: $1)
        },
        probeBuilder: ChannelProbeBuilder = .init()
    ) {
        self.socketFactory = socketFactory
        self.probeBuilder = probeBuilder
    }

    public func establishChannel(
        to host: MoonlightHost,
        descriptor: ChannelDescriptor
    ) async throws -> EstablishedChannel {
        guard descriptor.port != 0 else {
            throw MoonlightError(.unsupportedOperation, message: "Cannot establish channel with port 0")
        }

        if descriptor.metadata["connectData"] != nil,
           descriptor.kind == .control || descriptor.kind == .input
        {
            return EstablishedChannel(descriptor: descriptor, isConnected: true)
        }

        var establishedDescriptor = descriptor
        if descriptor.kind == .video || descriptor.kind == .audio {
            let socket = try socketFactory(host.endpoint.address, descriptor.port)
            do {
                establishedDescriptor.metadata["localPort"] = String(try await socket.localPort())
                if let probe = try probeBuilder.makeProbe(for: descriptor) {
                    try await socket.send(probe)
                }
                await socket.close()
            } catch {
                await socket.close()
                throw error
            }
            return EstablishedChannel(descriptor: establishedDescriptor, isConnected: true)
        }

        let socket = try socketFactory(host.endpoint.address, descriptor.port)
        establishedDescriptor.metadata["localPort"] = String(try await socket.localPort())
        return EstablishedChannel(descriptor: establishedDescriptor, isConnected: true)
    }
}

public struct ChannelProbeBuilder: Sendable {
    public init() {}

    public func makeProbe(for descriptor: ChannelDescriptor) throws -> Data? {
        switch descriptor.kind {
        case .video, .audio:
            guard let pingPayload = descriptor.metadata["pingPayload"] else {
                return Data("PING".utf8)
            }
            return try makeSunshinePingPacket(payload: pingPayload)
        case .control, .input:
            return nil
        }
    }

    private func makeSunshinePingPacket(payload: String) throws -> Data {
        let payloadData = Data(payload.utf8)
        guard payloadData.count == 16 else {
            throw MoonlightError(.unsupportedOperation, message: "Sunshine ping payload must be 16 bytes")
        }

        var packet = Data()
        packet.append(payloadData)

        var sequenceNumber = UInt32(0).bigEndian
        withUnsafeBytes(of: &sequenceNumber) { packet.append(contentsOf: $0) }
        return packet
    }
}
