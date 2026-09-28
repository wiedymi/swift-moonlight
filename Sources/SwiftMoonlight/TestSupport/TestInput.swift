import Foundation

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
