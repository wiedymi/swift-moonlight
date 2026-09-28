import Foundation

public actor SimpleAudioDepacketizer {
    private let reorderWindowSize: Int
    private var nextSequenceNumber: UInt16?
    private var lastTimestamp: UInt32?
    private var lastTimestampStep: UInt32 = 960
    private var pendingPackets: [UInt16: AudioTransportPacket] = [:]
    private var concealedPacketCount = 0
    private var reorderedPacketCount = 0
    private var missingPacketCount = 0

    public init(reorderWindowSize: Int = 8) {
        self.reorderWindowSize = reorderWindowSize
    }

    public func submit(_ packet: AudioTransportPacket) throws -> EncodedAudioPacket? {
        if packet.rtp.packetType == AudioTransportPacket.fecPayloadType {
            return nil
        }
        guard packet.rtp.packetType == AudioTransportPacket.opusPayloadType else {
            return nil
        }

        if let nextSequenceNumber {
            if isSequenceBehind(packet.rtp.sequenceNumber, relativeTo: nextSequenceNumber) {
                return nil
            }
            if packet.rtp.sequenceNumber != nextSequenceNumber {
                reorderedPacketCount += 1
            }
        }
        pendingPackets[packet.rtp.sequenceNumber] = packet
        if nextSequenceNumber == nil {
            nextSequenceNumber = packet.rtp.sequenceNumber
        } else {
            let minimumPendingSequence = pendingPackets.keys
                .filter { !isSequenceBehind($0, relativeTo: nextSequenceNumber!) }
                .min { lhs, rhs in
                    sequenceDistanceForward(from: nextSequenceNumber!, to: lhs)
                        < sequenceDistanceForward(from: nextSequenceNumber!, to: rhs)
                } ?? packet.rtp.sequenceNumber
            if let nextSequenceNumber,
               sequenceDistanceForward(from: nextSequenceNumber, to: minimumPendingSequence) >= reorderWindowSize {
                return emitConcealmentPacket()
            }
        }

        if pendingPackets.count >= reorderWindowSize {
            return emitConcealmentPacket()
        }

        return drainPendingAudioPackets()
    }

    private func drainPendingAudioPackets() -> EncodedAudioPacket? {
        guard let nextSequenceNumber else {
            return nil
        }
        guard let packet = pendingPackets.removeValue(forKey: nextSequenceNumber) else {
            return nil
        }
        self.nextSequenceNumber = nextSequenceNumber &+ 1
        if let lastTimestamp {
            lastTimestampStep = max(1, packet.rtp.timestamp &- lastTimestamp)
        }
        lastTimestamp = packet.rtp.timestamp
        return EncodedAudioPacket(timestamp: UInt64(packet.rtp.timestamp), payload: packet.payload)
    }

    private func emitConcealmentPacket() -> EncodedAudioPacket? {
        guard let nextSequenceNumber else {
            return nil
        }
        self.nextSequenceNumber = nextSequenceNumber &+ 1
        concealedPacketCount += 1
        missingPacketCount += 1
        let concealedTimestamp = (lastTimestamp ?? 0) &+ lastTimestampStep
        lastTimestamp = concealedTimestamp
        return EncodedAudioPacket(timestamp: UInt64(concealedTimestamp), payload: Data(), isConcealment: true)
    }

    private func reset() {
        nextSequenceNumber = nil
        lastTimestamp = nil
        lastTimestampStep = 960
        pendingPackets.removeAll(keepingCapacity: false)
    }

    public func snapshotConcealedPacketCount() -> Int {
        concealedPacketCount
    }

    public func snapshotReorderedPacketCount() -> Int {
        reorderedPacketCount
    }

    public func snapshotMissingPacketCount() -> Int {
        missingPacketCount
    }
}
