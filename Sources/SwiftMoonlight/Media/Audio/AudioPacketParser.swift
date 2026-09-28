import Foundation

public struct AudioPacketParser: Sendable {
    public init() {}

    public func parse(_ packet: Data) throws -> AudioTransportPacket {
        let header = try parseRTPHeader(packet)
        guard packet.count >= header.payloadOffset else {
            throw MoonlightError(.invalidControlMessage, message: "Audio packet is too short")
        }

        return AudioTransportPacket(rtp: header.rtp, payload: Data(packet[header.payloadOffset...]))
    }
}
