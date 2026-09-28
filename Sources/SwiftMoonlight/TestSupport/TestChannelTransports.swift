import Foundation

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
