import Foundation

let expectedVideoRTPPayloadTypes: Set<UInt8> = [0, 96]

func readPacketUInt16BE(_ data: Data, offset: Int) -> UInt16 {
    let b0 = UInt16(data[data.startIndex.advanced(by: offset)])
    let b1 = UInt16(data[data.startIndex.advanced(by: offset + 1)])
    return (b0 << 8) | b1
}

func readPacketUInt32BE(_ data: Data, offset: Int) -> UInt32 {
    let b0 = UInt32(data[data.startIndex.advanced(by: offset)])
    let b1 = UInt32(data[data.startIndex.advanced(by: offset + 1)])
    let b2 = UInt32(data[data.startIndex.advanced(by: offset + 2)])
    let b3 = UInt32(data[data.startIndex.advanced(by: offset + 3)])
    return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
}

func readPacketUInt32LE(_ data: Data, offset: Int) -> UInt32 {
    let b0 = UInt32(data[data.startIndex.advanced(by: offset)])
    let b1 = UInt32(data[data.startIndex.advanced(by: offset + 1)])
    let b2 = UInt32(data[data.startIndex.advanced(by: offset + 2)])
    let b3 = UInt32(data[data.startIndex.advanced(by: offset + 3)])
    return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
}

func sequenceDistanceForward(from earlier: UInt16, to later: UInt16) -> Int {
    Int(later &- earlier)
}

func fecBlockLowestSequenceNumber(for packet: VideoTransportPacket) -> UInt16 {
    packet.rtp.sequenceNumber &- packet.video.fecShardIndex
}

func frameDistanceForward(from earlier: UInt32, to later: UInt32) -> UInt32 {
    later &- earlier
}

func countMissingSequences(
    from nextContiguousSequenceNumber: UInt16,
    to highestReceivedSequenceNumber: UInt16,
    receivedSequences: Set<UInt16>
) -> Int {
    var missing = 0
    var sequenceNumber = nextContiguousSequenceNumber

    while sequenceNumber != highestReceivedSequenceNumber {
        if !receivedSequences.contains(sequenceNumber) {
            missing += 1
        }
        sequenceNumber = sequenceNumber &+ 1
    }

    return missing
}

func isSequenceBehind(_ sequenceNumber: UInt16, relativeTo expectedSequenceNumber: UInt16) -> Bool {
    let delta = expectedSequenceNumber &- sequenceNumber
    return delta != 0 && delta < 0x8000
}

struct ParsedRTPHeader {
    var rtp: RTPHeader
    var payloadOffset: Int
}

func parseVideoPacketHeader(_ packet: Data) throws -> ParsedRTPHeader {
    if isLikelyRTPv2(packet) {
        do {
            return try parseRTPHeader(packet)
        } catch {
            if packet.count < VideoPacketHeader.size {
                throw error
            }
            // Some bare NV video packets can begin with bytes that superficially
            // resemble RTP. If header validation fails, fall back to the bare shape.
        }
    }

    if packet.count >= VideoPacketHeader.size {
        let sequence = UInt16(truncatingIfNeeded: readPacketUInt32LE(packet, offset: 0))
        let timestamp = readPacketUInt32LE(packet, offset: 4)
        return ParsedRTPHeader(
            rtp: RTPHeader(
                hasExtension: false,
                packetType: 0,
                sequenceNumber: sequence,
                timestamp: timestamp,
                ssrc: 0
            ),
            payloadOffset: 0
        )
    }

    throw MoonlightError(.invalidControlMessage, message: "Video packet is too short")
}

func isLikelyRTPv2(_ packet: Data) -> Bool {
    guard packet.count >= RTPHeader.fixedSize else {
        return false
    }
    guard (packet[0] & 0xC0) == 0x80 else {
        return false
    }
    guard (packet[0] & 0x0F) == 0 else {
        return false
    }
    let payloadType = packet[1] & 0x7F
    return expectedVideoRTPPayloadTypes.contains(payloadType)
}

func parseRTPHeader(_ packet: Data) throws -> ParsedRTPHeader {
    guard packet.count >= RTPHeader.fixedSize else {
        throw MoonlightError(.invalidControlMessage, message: "RTP packet is too short")
    }

    let firstByte = packet[0]
    let csrcCount = Int(firstByte & 0x0F)
    let hasExtension = (firstByte & 0x10) != 0
    var offset = RTPHeader.fixedSize + (csrcCount * 4)
    guard packet.count >= offset else {
        throw MoonlightError(.invalidControlMessage, message: "RTP packet is truncated before payload")
    }

    if hasExtension {
        guard packet.count >= offset + 4 else {
            throw MoonlightError(.invalidControlMessage, message: "RTP extension header is truncated")
        }

        let extensionLengthWords = Int(readPacketUInt16BE(packet, offset: offset + 2))
        offset += 4 + (extensionLengthWords * 4)
        guard packet.count >= offset else {
            throw MoonlightError(.invalidControlMessage, message: "RTP extension payload is truncated")
        }
    }

    return ParsedRTPHeader(
        rtp: RTPHeader(
            hasExtension: hasExtension,
            packetType: packet[1] & 0x7F,
            sequenceNumber: readPacketUInt16BE(packet, offset: 2),
            timestamp: readPacketUInt32BE(packet, offset: 4),
            ssrc: readPacketUInt32BE(packet, offset: 8)
        ),
        payloadOffset: offset
    )
}
