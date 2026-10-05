import Foundation

public struct VideoDepacketizerConfiguration: Sendable, Equatable {
    public var codec: VideoCodec
    public var dimensions: CGSize
    public var frameHeaderSize: Int
    public var reorderWindowSize: Int {
        didSet { reorderWindowSize = min(max(reorderWindowSize, 1), 32_767) }
    }

    public init(
        codec: VideoCodec,
        dimensions: CGSize,
        frameHeaderSize: Int = 8,
        reorderWindowSize: Int = 64
    ) {
        self.codec = codec
        self.dimensions = dimensions
        self.frameHeaderSize = frameHeaderSize
        self.reorderWindowSize = min(max(reorderWindowSize, 1), 32_767)
    }
}

private struct VideoFECBlockObservation {
    var frameIndex: UInt32
    var dataShardCount: UInt16
    var fecPercentage: UInt8
    var multiFecBlockIndex: UInt8
    var multiFecBlockCount: UInt8
    var receivedDataShards: Set<UInt16> = []
    var receivedParityShards: Set<UInt16> = []
    var receivedSequenceNumbers: Set<UInt16> = []
    var packetsByShardIndex: [UInt16: VideoTransportPacket] = [:]
    var lowestSequenceNumber: UInt16
    var highestReceivedSequenceNumber: UInt16

    init?(packet: VideoTransportPacket) {
        guard packet.video.dataShardCount > 0 else {
            return nil
        }

        frameIndex = packet.video.frameIndex
        dataShardCount = packet.video.dataShardCount
        fecPercentage = packet.video.fecPercentage
        multiFecBlockIndex = packet.video.fecBlockIndex
        multiFecBlockCount = packet.video.fecLastBlockIndex + 1
        lowestSequenceNumber = fecBlockLowestSequenceNumber(for: packet)
        highestReceivedSequenceNumber = packet.rtp.sequenceNumber
        record(packet)
    }

    func canRecord(_ packet: VideoTransportPacket) -> Bool {
        packet.video.dataShardCount > 0
            && packet.video.frameIndex == frameIndex
            && packet.video.dataShardCount == dataShardCount
            && packet.video.fecPercentage == fecPercentage
            && packet.video.fecBlockIndex == multiFecBlockIndex
            && packet.video.fecLastBlockIndex + 1 == multiFecBlockCount
            && fecBlockLowestSequenceNumber(for: packet) == lowestSequenceNumber
    }

    mutating func record(_ packet: VideoTransportPacket) {
        guard canRecord(packet) else {
            return
        }

        receivedSequenceNumbers.insert(packet.rtp.sequenceNumber)
        packetsByShardIndex[packet.video.fecShardIndex] = packet
        if isSequenceBehind(highestReceivedSequenceNumber, relativeTo: packet.rtp.sequenceNumber) {
            highestReceivedSequenceNumber = packet.rtp.sequenceNumber
        }

        if packet.video.isParityShard {
            receivedParityShards.insert(packet.video.fecShardIndex)
        } else if packet.video.fecShardIndex < dataShardCount {
            receivedDataShards.insert(packet.video.fecShardIndex)
        }
    }

    func makeStatus(
        highestReceivedSequenceNumber: UInt16,
        nextContiguousSequenceNumber: UInt16,
        missingPacketsBeforeHighestReceived: UInt16
    ) -> VideoFrameFECStatus {
        VideoFrameFECStatus(
            frameIndex: frameIndex,
            highestReceivedSequenceNumber: highestReceivedSequenceNumber,
            nextContiguousSequenceNumber: nextContiguousSequenceNumber,
            missingPacketsBeforeHighestReceived: missingPacketsBeforeHighestReceived,
            totalDataPackets: dataShardCount,
            totalParityPackets: UInt16(clamping: (Int(dataShardCount) * Int(fecPercentage) + 99) / 100),
            receivedDataPackets: UInt16(clamping: receivedDataShards.count),
            receivedParityPackets: UInt16(clamping: receivedParityShards.count),
            fecPercentage: fecPercentage,
            multiFecBlockIndex: multiFecBlockIndex,
            multiFecBlockCount: multiFecBlockCount
        )
    }
}

public actor SimpleVideoDepacketizer {
    private let configuration: VideoDepacketizerConfiguration
    private let fecRecoverer = VideoFECBlockRecoverer()
    private var currentFrameIndex: UInt32?
    private var currentTimestamp: UInt32?
    private var currentFrameIsKeyFrame = false
    private var lastCompletedFrameIndex: UInt32?
    private var currentFECBlock: VideoFECBlockObservation?
    private var pendingFECStatuses: [VideoFrameFECStatus] = []
    private var bufferedPayload = Data()
    private var nextSequenceNumber: UInt16?
    private var pendingPackets: [UInt16: VideoTransportPacket] = [:]
    private var highestReceivedSequenceNumber: UInt16?
    private var submittedPacketCount = 0
    private var reorderedPacketCount = 0
    private var discontinuityCount = 0
    private var missingPacketCount = 0

    public init(configuration: VideoDepacketizerConfiguration) {
        self.configuration = configuration
    }

    public func submit(_ packet: VideoTransportPacket) throws -> EncodedVideoFrame? {
        submittedPacketCount += 1
        if let nextSequenceNumber {
            if isSequenceBehind(packet.rtp.sequenceNumber, relativeTo: nextSequenceNumber) {
                return nil
            }
            if let highestReceivedSequenceNumber,
               isSequenceBehind(packet.rtp.sequenceNumber, relativeTo: highestReceivedSequenceNumber) {
                reorderedPacketCount += 1
            }
        }
        if highestReceivedSequenceNumber == nil ||
            isSequenceBehind(highestReceivedSequenceNumber!, relativeTo: packet.rtp.sequenceNumber) {
            highestReceivedSequenceNumber = packet.rtp.sequenceNumber
        }
        pendingPackets[packet.rtp.sequenceNumber] = packet
        recordFECObservation(for: packet)

        if nextSequenceNumber == nil {
            if packet.video.isStartOfFrame {
                nextSequenceNumber = packet.rtp.sequenceNumber
            } else if let currentFECBlock {
                nextSequenceNumber = currentFECBlock.lowestSequenceNumber
            } else if pendingPackets.count > configuration.reorderWindowSize {
                pendingPackets.removeAll(keepingCapacity: false)
                highestReceivedSequenceNumber = nil
            }
        } else {
            let gap = sequenceDistanceForward(from: nextSequenceNumber!, to: packet.rtp.sequenceNumber)
            if shouldAdvanceAcrossCompletedFrameGap(to: packet, gap: gap) {
                if hasSkippedFrames(before: packet.video.frameIndex) {
                    discontinuityCount += 1
                }
                nextSequenceNumber = packet.rtp.sequenceNumber
            } else if gap > effectiveReorderWindow(for: nextSequenceNumber!) {
                let recoveredGap = recoverPendingFECPackets(expectedSequenceNumber: nextSequenceNumber!)
                if !recoveredGap {
                    queueFECStatusForDiscontinuity(expectedSequenceNumber: nextSequenceNumber!)
                    // Gap too large — drop current partial frame and advance to the
                    // nearest available packet. Unlike a full reset, we keep
                    // nextSequenceNumber so we can continue draining from the new
                    // position and capture the next SOF (possibly an IDR).
                    discontinuityCount += 1
                    missingPacketCount += missingPacketsForDiscontinuity(
                        expectedSequenceNumber: nextSequenceNumber!,
                        fallbackGap: gap
                    )
                    dropCurrentFrame()
                    nextSequenceNumber = packet.rtp.sequenceNumber
                }
            }
        }

        let reorderWindow = nextSequenceNumber.map(effectiveReorderWindow(for:)) ?? configuration.reorderWindowSize
        if pendingPackets.count > reorderWindow * 2 {
            // Pending buffer grew too large — trim packets behind nextSequenceNumber
            if let next = nextSequenceNumber {
                pendingPackets = pendingPackets.filter {
                    !isSequenceBehind($0.key, relativeTo: next)
                }
            }
        }

        return drainPendingVideoPackets()
    }

    private func drainPendingVideoPackets() -> EncodedVideoFrame? {
        guard var expectedSequenceNumber = nextSequenceNumber else {
            return nil
        }

        while true {
            guard let packet = pendingPackets.removeValue(forKey: expectedSequenceNumber) else {
                if recoverPendingFECPackets(expectedSequenceNumber: expectedSequenceNumber) {
                    continue
                }
                return nil
            }

            nextSequenceNumber = expectedSequenceNumber &+ 1

            // Raw FEC parity packets can reach this boundary with garbage values
            // in the NVIDIA header fields. They still consume RTP sequence numbers
            // but must not contribute bytes or state transitions to frame assembly.
            if packet.video.isParityShard || !packet.video.hasKnownFlagBitsOnly {
                recordFECObservation(for: packet)
                expectedSequenceNumber = expectedSequenceNumber &+ 1
                continue
            }

            if packet.video.isStartOfFrame {
                currentFrameIndex = packet.video.frameIndex
                currentTimestamp = packet.rtp.timestamp
                bufferedPayload.removeAll(keepingCapacity: true)
                currentFECBlock = VideoFECBlockObservation(packet: packet)
                currentFrameIsKeyFrame = detectKeyFrameFromHeader(packet.payload)
                let payload = trimFrameHeader(from: packet.payload)
                if !currentFrameIsKeyFrame {
                    currentFrameIsKeyFrame = detectKeyFrame(payload: payload, codec: configuration.codec)
                }
                bufferedPayload.append(payload)
            } else if currentFrameIndex == packet.video.frameIndex {
                recordFECObservation(for: packet)
                bufferedPayload.append(packet.payload)
            } else {
                // Packet belongs to a different frame and we missed the SOF.
                // Drop the current frame and keep advancing.
                dropCurrentFrame()
                expectedSequenceNumber = expectedSequenceNumber &+ 1
                continue
            }

            expectedSequenceNumber = expectedSequenceNumber &+ 1

            guard packet.video.isEndOfFrame else {
                continue
            }

            let frame = EncodedVideoFrame(
                timestamp: UInt64(currentTimestamp ?? packet.rtp.timestamp),
                isKeyFrame: currentFrameIsKeyFrame,
                codec: configuration.codec,
                hostProcessingLatencyMs: packet.hostProcessingLatencyMs,
                payload: bufferedPayload
            )
            lastCompletedFrameIndex = packet.video.frameIndex
            dropCurrentFrame()
            return frame
        }
    }

    private func effectiveReorderWindow(for expectedSequenceNumber: UInt16) -> Int {
        guard let observation = currentFECBlock else { return configuration.reorderWindowSize }
        let dataCount = Int(observation.dataShardCount)
        let parityCount = (dataCount * Int(observation.fecPercentage) + 99) / 100
        let totalCount = dataCount + parityCount
        let expectedIndex = sequenceDistanceForward(
            from: observation.lowestSequenceNumber, to: expectedSequenceNumber
        )
        // Only a valid repair block can extend the configured reorder window.
        // Its final parity packet must arrive before we decide that repair failed.
        guard dataCount > 0, parityCount > 0, totalCount <= 255, expectedIndex < dataCount else {
            return configuration.reorderWindowSize
        }
        return max(configuration.reorderWindowSize, totalCount - expectedIndex - 1)
    }

    private func shouldAdvanceAcrossCompletedFrameGap(to packet: VideoTransportPacket, gap: Int) -> Bool {
        gap > 0 && currentFrameIndex == nil && packet.video.isStartOfFrame
    }

    private func hasSkippedFrames(before frameIndex: UInt32) -> Bool {
        guard let lastCompletedFrameIndex else {
            return false
        }

        let distance = frameDistanceForward(from: lastCompletedFrameIndex, to: frameIndex)
        return distance > 1 && distance < 0x8000_0000
    }

    private func dropCurrentFrame() {
        currentFrameIndex = nil
        currentTimestamp = nil
        currentFrameIsKeyFrame = false
        currentFECBlock = nil
        bufferedPayload.removeAll(keepingCapacity: true)
    }

    private func missingPacketsForDiscontinuity(expectedSequenceNumber: UInt16, fallbackGap: Int) -> Int {
        guard currentFrameIndex != nil || currentFECBlock != nil else {
            return 0
        }

        guard var observation = currentFECBlock else {
            return fallbackGap
        }

        for packet in pendingPackets.values where observation.canRecord(packet) {
            observation.record(packet)
        }
        currentFECBlock = observation

        let highest = observation.highestReceivedSequenceNumber
        guard !isSequenceBehind(highest, relativeTo: expectedSequenceNumber) else {
            return fallbackGap
        }

        let firstMissingSequence = firstMissingSequenceForCurrentDiscontinuity(
            expectedSequenceNumber: expectedSequenceNumber,
            observation: observation
        )
        let missing = countMissingSequences(
            from: firstMissingSequence,
            to: highest,
            receivedSequences: observation.receivedSequenceNumbers
        )
        return max(1, missing)
    }

    private func firstMissingSequenceForCurrentDiscontinuity(
        expectedSequenceNumber: UInt16,
        observation: VideoFECBlockObservation
    ) -> UInt16 {
        guard currentFrameIndex == nil,
              isSequenceBehind(expectedSequenceNumber, relativeTo: observation.lowestSequenceNumber)
        else {
            return expectedSequenceNumber
        }

        return observation.lowestSequenceNumber
    }

    private func recordFECObservation(for packet: VideoTransportPacket) {
        guard packet.video.dataShardCount > 0 else {
            return
        }

        if currentFECBlock?.canRecord(packet) == true {
            currentFECBlock?.record(packet)
            return
        }

        guard currentFrameIndex == nil || currentFrameIndex == packet.video.frameIndex else {
            return
        }
        currentFECBlock = VideoFECBlockObservation(packet: packet)
    }

    private func queueFECStatusForDiscontinuity(expectedSequenceNumber: UInt16) {
        guard var observation = currentFECBlock else {
            return
        }

        for packet in pendingPackets.values where observation.canRecord(packet) {
            observation.record(packet)
        }

        let highest = observation.highestReceivedSequenceNumber
        guard !isSequenceBehind(highest, relativeTo: expectedSequenceNumber) else {
            return
        }
        let firstMissingSequence = firstMissingSequenceForCurrentDiscontinuity(
            expectedSequenceNumber: expectedSequenceNumber,
            observation: observation
        )
        let missing = countMissingSequences(
            from: firstMissingSequence,
            to: highest,
            receivedSequences: observation.receivedSequenceNumbers
        )
        let status = observation.makeStatus(
            highestReceivedSequenceNumber: highest,
            nextContiguousSequenceNumber: firstMissingSequence,
            missingPacketsBeforeHighestReceived: UInt16(clamping: missing)
        )

        pendingFECStatuses.append(status)
        if pendingFECStatuses.count > 16 {
            pendingFECStatuses.removeFirst(pendingFECStatuses.count - 16)
        }
    }

    private func recoverPendingFECPackets(expectedSequenceNumber: UInt16) -> Bool {
        // A contiguous packet leaves no queued packet to repair around. Avoid
        // copying the block's shard dictionary after every healthy packet.
        guard !pendingPackets.isEmpty, var observation = currentFECBlock else {
            return false
        }
        let expectedIndex = sequenceDistanceForward(
            from: observation.lowestSequenceNumber, to: expectedSequenceNumber
        )
        guard expectedIndex < Int(observation.dataShardCount) else { return false }

        for packet in pendingPackets.values where observation.canRecord(packet) {
            observation.record(packet)
        }

        let packets = Array(observation.packetsByShardIndex.values)
        guard packets.count >= Int(observation.dataShardCount) else {
            currentFECBlock = observation
            return false
        }

        guard let recovered = try? fecRecoverer.recoverMissingDataPackets(from: packets) else {
            currentFECBlock = observation
            return false
        }

        var recoveredExpectedPacket = false
        for packet in recovered where !isSequenceBehind(packet.rtp.sequenceNumber, relativeTo: expectedSequenceNumber) {
            guard pendingPackets[packet.rtp.sequenceNumber] == nil else {
                continue
            }
            pendingPackets[packet.rtp.sequenceNumber] = packet
            observation.record(packet)
            if packet.rtp.sequenceNumber == expectedSequenceNumber {
                recoveredExpectedPacket = true
            }
        }
        currentFECBlock = observation
        return recoveredExpectedPacket
    }

    private func trimFrameHeader(from payload: Data) -> Data {
        let frameHeaderSize = resolvedFrameHeaderSize(for: payload)
        guard frameHeaderSize > 0, payload.count >= frameHeaderSize else {
            return payload
        }
        return Data(payload.dropFirst(frameHeaderSize))
    }

    private func resolvedFrameHeaderSize(for payload: Data) -> Int {
        guard configuration.frameHeaderSize == 8, let marker = payload.first else {
            return configuration.frameHeaderSize
        }

        switch marker {
        case 0x01:
            return 8
        case 0x81:
            // Observed Sunshine/Apollo 7.1.415...7.1.445 long first-packet header.
            return 24
        default:
            return configuration.frameHeaderSize
        }
    }

    private func fullReset() {
        dropCurrentFrame()
        nextSequenceNumber = nil
        highestReceivedSequenceNumber = nil
        lastCompletedFrameIndex = nil
        pendingPackets.removeAll(keepingCapacity: false)
    }

    /// Detect keyframe from the Moonlight/Sunshine frame header byte at offset 3.
    /// This byte indicates the encoder's frame type: 1=P-frame, 2=IDR, 4=intra-refresh, 5=RFI.
    private func detectKeyFrameFromHeader(_ rawPayload: Data) -> Bool {
        let headerSize = resolvedFrameHeaderSize(for: rawPayload)
        guard headerSize >= 4, rawPayload.count >= 4 else { return false }
        return rawPayload[rawPayload.startIndex + 3] == 0x02
    }

    private func detectKeyFrame(payload: Data, codec: VideoCodec) -> Bool {
        guard payload.count >= 5 else { return false }

        // Check the Sunshine frame header type byte that precedes the NAL data.
        // Header byte at original payload offset 3 indicates frame type:
        // 1 = P-frame, 2 = IDR frame, 4 = intra-refresh, 5 = RFI P-frame
        // If we get here, the frame header has already been trimmed, but the
        // presence of parameter sets in the bitstream is the authoritative signal.
        switch codec {
        case .hevc:
            return AnnexBBitstream.containsParameterSets(payload, codec: .hevc)
        case .h264:
            return AnnexBBitstream.containsParameterSets(payload, codec: .h264)
        case .av1:
            return false
        }
    }

    /// Reset all depacketizer state. Called after an IDR request so the next
    /// frame received (the keyframe) is captured from its very first packet
    /// without interference from stale sequence tracking.
    public func flushForKeyframeRequest() {
        fullReset()
    }

    public func drainPendingFrameFECStatuses() -> [VideoFrameFECStatus] {
        defer {
            pendingFECStatuses.removeAll(keepingCapacity: true)
        }
        return pendingFECStatuses
    }

    public func snapshotReorderedPacketCount() -> Int {
        reorderedPacketCount
    }

    public func snapshotDiscontinuityCount() -> Int {
        discontinuityCount
    }

    public func snapshotMissingPacketCount() -> Int {
        missingPacketCount
    }

    public func snapshot() -> VideoDepacketizerSnapshot {
        VideoDepacketizerSnapshot(
            reorderedPacketCount: reorderedPacketCount,
            missingPacketCount: missingPacketCount,
            discontinuityCount: discontinuityCount
        )
    }
}
