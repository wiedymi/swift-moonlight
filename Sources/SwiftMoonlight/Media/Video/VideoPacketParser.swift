import Foundation

public struct VideoPacketParser: Sendable {
    public init() {}

    public func parse(_ packet: Data) throws -> VideoTransportPacket {
        let header = try parseVideoPacketHeader(packet)
        let videoOffset = header.payloadOffset
        guard packet.count >= videoOffset + VideoPacketHeader.size else {
            throw MoonlightError(.invalidControlMessage, message: "Video packet is too short")
        }

        let video = VideoPacketHeader(
            streamPacketIndex: readPacketUInt32LE(packet, offset: videoOffset),
            frameIndex: readPacketUInt32LE(packet, offset: videoOffset + 4),
            flags: packet[videoOffset + 8],
            extraFlags: packet[videoOffset + 9],
            multiFecFlags: packet[videoOffset + 10],
            multiFecBlocks: packet[videoOffset + 11],
            fecInfo: readPacketUInt32LE(packet, offset: videoOffset + 12)
        )

        let protectedPayload = Data(packet[videoOffset...])
        let videoPayload = Data(packet[(videoOffset + VideoPacketHeader.size)...])
        return VideoTransportPacket(
            rtp: header.rtp,
            video: video,
            hostProcessingLatencyMs: parseHostProcessingLatency(from: videoPayload),
            payload: videoPayload,
            fecProtectedPayload: protectedPayload
        )
    }

    private func parseHostProcessingLatency(from payload: Data) -> Double? {
        guard payload.count >= 3 else {
            return nil
        }
        let rawTenthsMs = UInt16(payload[1]) | (UInt16(payload[2]) << 8)
        guard rawTenthsMs > 0 else {
            return nil
        }
        return Double(rawTenthsMs) / 10.0
    }
}
