import Foundation

public struct RTPHeader: Sendable, Equatable {
    public static let fixedSize = 12

    public var hasExtension: Bool
    public var packetType: UInt8
    public var sequenceNumber: UInt16
    public var timestamp: UInt32
    public var ssrc: UInt32

    public init(
        hasExtension: Bool = false,
        packetType: UInt8,
        sequenceNumber: UInt16,
        timestamp: UInt32,
        ssrc: UInt32
    ) {
        self.hasExtension = hasExtension
        self.packetType = packetType
        self.sequenceNumber = sequenceNumber
        self.timestamp = timestamp
        self.ssrc = ssrc
    }
}

public struct VideoPacketHeader: Sendable, Equatable {
    public static let size = 16

    public static let containsPictureDataFlag: UInt8 = 0x01
    public static let endOfFrameFlag: UInt8 = 0x02
    public static let startOfFrameFlag: UInt8 = 0x04

    public var streamPacketIndex: UInt32
    public var frameIndex: UInt32
    public var flags: UInt8
    public var extraFlags: UInt8
    public var multiFecFlags: UInt8
    public var multiFecBlocks: UInt8
    public var fecInfo: UInt32

    public init(
        streamPacketIndex: UInt32,
        frameIndex: UInt32,
        flags: UInt8,
        extraFlags: UInt8,
        multiFecFlags: UInt8,
        multiFecBlocks: UInt8,
        fecInfo: UInt32
    ) {
        self.streamPacketIndex = streamPacketIndex
        self.frameIndex = frameIndex
        self.flags = flags
        self.extraFlags = extraFlags
        self.multiFecFlags = multiFecFlags
        self.multiFecBlocks = multiFecBlocks
        self.fecInfo = fecInfo
    }

    public var isStartOfFrame: Bool {
        flags & Self.startOfFrameFlag != 0 && fecBlockIndex == 0
    }

    public var isEndOfFrame: Bool {
        flags & Self.endOfFrameFlag != 0 && fecBlockIndex == fecLastBlockIndex
    }

    public var fecShardIndex: UInt16 {
        UInt16((fecInfo & 0x003F_F000) >> 12)
    }

    public var dataShardCount: UInt16 {
        UInt16((fecInfo & 0xFFC0_0000) >> 22)
    }

    public var fecPercentage: UInt8 {
        UInt8((fecInfo & 0x0000_0FF0) >> 4)
    }

    public var fecBlockIndex: UInt8 {
        (multiFecBlocks >> 4) & 0x03
    }

    public var fecLastBlockIndex: UInt8 {
        (multiFecBlocks >> 6) & 0x03
    }

    public var isParityShard: Bool {
        dataShardCount > 0 && fecShardIndex >= dataShardCount
    }

    public var hasKnownFlagBitsOnly: Bool {
        flags & ~(Self.containsPictureDataFlag | Self.endOfFrameFlag | Self.startOfFrameFlag) == 0
    }
}

public struct VideoTransportPacket: Sendable, Equatable {
    public var rtp: RTPHeader
    public var video: VideoPacketHeader
    public var hostProcessingLatencyMs: Double?
    public var payload: Data
    public var fecProtectedPayload: Data

    public init(
        rtp: RTPHeader,
        video: VideoPacketHeader,
        hostProcessingLatencyMs: Double? = nil,
        payload: Data,
        fecProtectedPayload: Data? = nil
    ) {
        self.rtp = rtp
        self.video = video
        self.hostProcessingLatencyMs = hostProcessingLatencyMs
        self.payload = payload
        self.fecProtectedPayload = fecProtectedPayload ?? makeFECProtectedPayload(video: video, payload: payload)
    }
}

public struct VideoPacketTraceEntry: Sendable, Equatable, Codable {
    public var observedPacketIndex: Int
    public var usedDecryptor: Bool
    public var usedSyntheticSequenceNumber: Bool
    public var encryptedByteCount: Int
    public var rawByteCount: Int
    public var sequenceNumber: UInt16
    public var packetType: UInt8
    public var timestamp: UInt32
    public var streamPacketIndex: UInt32
    public var frameIndex: UInt32
    public var flags: UInt8
    public var fecShardIndex: UInt16
    public var dataShardCount: UInt16
    public var fecPercentage: UInt8
    public var fecBlockIndex: UInt8
    public var fecLastBlockIndex: UInt8
    public var isStartOfFrame: Bool
    public var isEndOfFrame: Bool
    public var isParityShard: Bool

    public init(
        observedPacketIndex: Int,
        usedDecryptor: Bool,
        usedSyntheticSequenceNumber: Bool,
        encryptedByteCount: Int,
        rawByteCount: Int,
        sequenceNumber: UInt16,
        packetType: UInt8,
        timestamp: UInt32,
        streamPacketIndex: UInt32,
        frameIndex: UInt32,
        flags: UInt8,
        fecShardIndex: UInt16,
        dataShardCount: UInt16,
        fecPercentage: UInt8,
        fecBlockIndex: UInt8,
        fecLastBlockIndex: UInt8,
        isStartOfFrame: Bool,
        isEndOfFrame: Bool,
        isParityShard: Bool
    ) {
        self.observedPacketIndex = observedPacketIndex
        self.usedDecryptor = usedDecryptor
        self.usedSyntheticSequenceNumber = usedSyntheticSequenceNumber
        self.encryptedByteCount = encryptedByteCount
        self.rawByteCount = rawByteCount
        self.sequenceNumber = sequenceNumber
        self.packetType = packetType
        self.timestamp = timestamp
        self.streamPacketIndex = streamPacketIndex
        self.frameIndex = frameIndex
        self.flags = flags
        self.fecShardIndex = fecShardIndex
        self.dataShardCount = dataShardCount
        self.fecPercentage = fecPercentage
        self.fecBlockIndex = fecBlockIndex
        self.fecLastBlockIndex = fecLastBlockIndex
        self.isStartOfFrame = isStartOfFrame
        self.isEndOfFrame = isEndOfFrame
        self.isParityShard = isParityShard
    }
}

public struct VideoFrameFECStatus: Sendable, Equatable {
    public var frameIndex: UInt32
    public var highestReceivedSequenceNumber: UInt16
    public var nextContiguousSequenceNumber: UInt16
    public var missingPacketsBeforeHighestReceived: UInt16
    public var totalDataPackets: UInt16
    public var totalParityPackets: UInt16
    public var receivedDataPackets: UInt16
    public var receivedParityPackets: UInt16
    public var fecPercentage: UInt8
    public var multiFecBlockIndex: UInt8
    public var multiFecBlockCount: UInt8

    public init(
        frameIndex: UInt32,
        highestReceivedSequenceNumber: UInt16,
        nextContiguousSequenceNumber: UInt16,
        missingPacketsBeforeHighestReceived: UInt16,
        totalDataPackets: UInt16,
        totalParityPackets: UInt16,
        receivedDataPackets: UInt16,
        receivedParityPackets: UInt16,
        fecPercentage: UInt8,
        multiFecBlockIndex: UInt8,
        multiFecBlockCount: UInt8
    ) {
        self.frameIndex = frameIndex
        self.highestReceivedSequenceNumber = highestReceivedSequenceNumber
        self.nextContiguousSequenceNumber = nextContiguousSequenceNumber
        self.missingPacketsBeforeHighestReceived = missingPacketsBeforeHighestReceived
        self.totalDataPackets = totalDataPackets
        self.totalParityPackets = totalParityPackets
        self.receivedDataPackets = receivedDataPackets
        self.receivedParityPackets = receivedParityPackets
        self.fecPercentage = fecPercentage
        self.multiFecBlockIndex = multiFecBlockIndex
        self.multiFecBlockCount = multiFecBlockCount
    }
}

public struct VideoDepacketizerSnapshot: Sendable, Equatable {
    public var reorderedPacketCount: Int
    public var missingPacketCount: Int
    public var discontinuityCount: Int

    public init(reorderedPacketCount: Int, missingPacketCount: Int, discontinuityCount: Int) {
        self.reorderedPacketCount = reorderedPacketCount
        self.missingPacketCount = missingPacketCount
        self.discontinuityCount = discontinuityCount
    }
}

public struct VideoIngestSnapshot: Sendable, Equatable {
    public var observedPacketCount: Int
    public var reorderedPacketCount: Int
    public var missingPacketCount: Int
    public var discontinuityCount: Int
    public var recoverableDecodeFailureCount: Int
    public var packetTrace: [VideoPacketTraceEntry]

    public init(
        observedPacketCount: Int,
        reorderedPacketCount: Int,
        missingPacketCount: Int,
        discontinuityCount: Int,
        recoverableDecodeFailureCount: Int,
        packetTrace: [VideoPacketTraceEntry] = []
    ) {
        self.observedPacketCount = observedPacketCount
        self.reorderedPacketCount = reorderedPacketCount
        self.missingPacketCount = missingPacketCount
        self.discontinuityCount = discontinuityCount
        self.recoverableDecodeFailureCount = recoverableDecodeFailureCount
        self.packetTrace = packetTrace
    }
}

public struct AudioTransportPacket: Sendable, Equatable {
    public static let opusPayloadType: UInt8 = 97
    public static let fecPayloadType: UInt8 = 127

    public var rtp: RTPHeader
    public var payload: Data

    public init(rtp: RTPHeader, payload: Data) {
        self.rtp = rtp
        self.payload = payload
    }
}

private let expectedVideoRTPPayloadTypes: Set<UInt8> = [0, 96]

public struct VideoPacketParser: Sendable {
    public init() {}

    public func parse(_ packet: Data) throws -> VideoTransportPacket {
        let header = try parseVideoPacketHeader(packet)
        let videoOffset = header.payloadOffset
        guard packet.count >= videoOffset + VideoPacketHeader.size else {
            throw MoonlightError(.invalidControlMessage, message: "Video packet is too short")
        }

        let video = VideoPacketHeader(
            streamPacketIndex: readUInt32LE(packet, offset: videoOffset),
            frameIndex: readUInt32LE(packet, offset: videoOffset + 4),
            flags: packet[videoOffset + 8],
            extraFlags: packet[videoOffset + 9],
            multiFecFlags: packet[videoOffset + 10],
            multiFecBlocks: packet[videoOffset + 11],
            fecInfo: readUInt32LE(packet, offset: videoOffset + 12)
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

public struct VideoDepacketizerConfiguration: Sendable, Equatable {
    public var codec: VideoCodec
    public var dimensions: CGSize
    public var frameHeaderSize: Int
    public var reorderWindowSize: Int

    public init(
        codec: VideoCodec,
        dimensions: CGSize,
        frameHeaderSize: Int = 8,
        reorderWindowSize: Int = 64
    ) {
        self.codec = codec
        self.dimensions = dimensions
        self.frameHeaderSize = frameHeaderSize
        self.reorderWindowSize = reorderWindowSize
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
            } else if gap > configuration.reorderWindowSize {
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

        if pendingPackets.count > configuration.reorderWindowSize * 2 {
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
        guard var observation = currentFECBlock else {
            return false
        }

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

public enum VideoPipelineSubmissionMode: Sendable, Equatable {
    case synchronous
    case asynchronous(maxInFlightFrames: Int)

    var boundedMaxInFlightFrames: Int? {
        switch self {
        case .synchronous:
            return nil
        case .asynchronous(let maxInFlightFrames):
            return max(1, maxInFlightFrames)
        }
    }
}

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

public actor VideoIngestService {
    private let source: MediaPacketSource
    private let decryptor: VideoPacketDecryptor?
    private let encryptionContext: VideoEncryptionContext?
    private let parser: VideoPacketParser
    private let depacketizer: SimpleVideoDepacketizer
    private let pipeline: MediaPipeline
    private let packetTraceLimit: Int
    private let pipelineSubmissionMode: VideoPipelineSubmissionMode
    private var observedPacketCount = 0
    private var recoverableDecodeFailureCount = 0
    private var packetTrace: [VideoPacketTraceEntry] = []
    private var pendingPipelineError: MoonlightError?
    private var inFlightPipelineTasks: [Task<Void, Never>] = []

    public init(
        source: MediaPacketSource,
        decryptor: VideoPacketDecryptor? = nil,
        encryptionContext: VideoEncryptionContext? = nil,
        parser: VideoPacketParser = .init(),
        depacketizer: SimpleVideoDepacketizer,
        pipeline: MediaPipeline,
        packetTraceLimit: Int = 0,
        pipelineSubmissionMode: VideoPipelineSubmissionMode = .synchronous
    ) {
        self.source = source
        self.decryptor = decryptor
        self.encryptionContext = encryptionContext
        self.parser = parser
        self.depacketizer = depacketizer
        self.pipeline = pipeline
        self.packetTraceLimit = max(0, packetTraceLimit)
        self.pipelineSubmissionMode = pipelineSubmissionMode
    }

    public func receiveNextFrame() async throws -> EncodedVideoFrame? {
        try throwPendingPipelineErrorIfNeeded()

        while let packetData = try await source.receivePacket() {
            try throwPendingPipelineErrorIfNeeded()
            if let frame = try await processVideoPacketData(packetData) {
                try await submitVideoFrameToPipeline(frame)
                return frame
            }
        }
        try await waitForInFlightPipelineTasks()
        try throwPendingPipelineErrorIfNeeded()
        return nil
    }

    public func flushForKeyframeRequest() async {
        for task in inFlightPipelineTasks {
            task.cancel()
        }
        inFlightPipelineTasks.removeAll(keepingCapacity: true)
        pendingPipelineError = nil
        await depacketizer.flushForKeyframeRequest()
    }

    public func drainPendingFrameFECStatuses() async -> [VideoFrameFECStatus] {
        await depacketizer.drainPendingFrameFECStatuses()
    }

    public func snapshotObservedPacketCount() -> Int {
        observedPacketCount
    }

    public func snapshotReorderedPacketCount() async -> Int {
        await depacketizer.snapshotReorderedPacketCount()
    }

    public func snapshotDiscontinuityCount() async -> Int {
        await depacketizer.snapshotDiscontinuityCount()
    }

    public func snapshotMissingPacketCount() async -> Int {
        await depacketizer.snapshotMissingPacketCount()
    }

    public func snapshotRecoverableDecodeFailureCount() -> Int {
        recoverableDecodeFailureCount
    }

    public func snapshotPacketTrace() -> [VideoPacketTraceEntry] {
        packetTrace
    }

    public func snapshot() async -> VideoIngestSnapshot {
        let depacketizerSnapshot = await depacketizer.snapshot()
        return VideoIngestSnapshot(
            observedPacketCount: observedPacketCount,
            reorderedPacketCount: depacketizerSnapshot.reorderedPacketCount,
            missingPacketCount: depacketizerSnapshot.missingPacketCount,
            discontinuityCount: depacketizerSnapshot.discontinuityCount,
            recoverableDecodeFailureCount: recoverableDecodeFailureCount,
            packetTrace: packetTrace
        )
    }

    private func processVideoPacketData(_ packetData: Data) async throws -> EncodedVideoFrame? {
        observedPacketCount += 1
        let rawPacket: Data
        let usedDecryptor = decryptor != nil && encryptionContext != nil
        if let decryptor, let encryptionContext {
            rawPacket = try decryptor.decrypt(packetData, context: encryptionContext)
        } else {
            rawPacket = packetData
        }
        let packet: VideoTransportPacket
        do {
            var parsedPacket = try parser.parse(rawPacket)
            let usedSyntheticSequenceNumber = !isLikelyRTPv2(rawPacket)
            if usedSyntheticSequenceNumber {
                parsedPacket.rtp.sequenceNumber = UInt16(truncatingIfNeeded: observedPacketCount)
            }
            recordPacketTrace(
                packet: parsedPacket,
                observedPacketIndex: observedPacketCount,
                usedDecryptor: usedDecryptor,
                usedSyntheticSequenceNumber: usedSyntheticSequenceNumber,
                encryptedByteCount: packetData.count,
                rawByteCount: rawPacket.count
            )
            packet = parsedPacket
        } catch {
            throw enrichVideoPacketError(
                error,
                observedPacketCount: observedPacketCount,
                usedDecryptor: usedDecryptor,
                packetData: packetData,
                rawPacket: rawPacket
            )
        }

        return try await depacketizer.submit(packet)
    }

    private func submitVideoFrameToPipeline(_ frame: EncodedVideoFrame) async throws {
        guard let maxInFlightFrames = pipelineSubmissionMode.boundedMaxInFlightFrames else {
            do {
                try await pipeline.ingestVideo(frame)
            } catch {
                guard Self.isRecoverableVideoDecodeError(error) else {
                    throw error
                }
                recoverableDecodeFailureCount += 1
            }
            return
        }

        try await applyPipelineBackpressure(maxInFlightFrames: maxInFlightFrames)
        let previousTask = inFlightPipelineTasks.last
        let task = Task.detached { [pipeline, previousTask] in
            if let previousTask {
                await previousTask.value
            }
            guard !Task.isCancelled else {
                return
            }
            do {
                try await pipeline.ingestVideo(frame)
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                await self.recordPipelineError(error)
            }
        }
        inFlightPipelineTasks.append(task)
    }

    private func applyPipelineBackpressure(maxInFlightFrames: Int) async throws {
        while inFlightPipelineTasks.count >= maxInFlightFrames {
            let task = inFlightPipelineTasks.removeFirst()
            await task.value
            try throwPendingPipelineErrorIfNeeded()
        }
    }

    private func waitForInFlightPipelineTasks() async throws {
        while !inFlightPipelineTasks.isEmpty {
            let task = inFlightPipelineTasks.removeFirst()
            await task.value
            try throwPendingPipelineErrorIfNeeded()
        }
    }

    private func recordPipelineError(_ error: Error) {
        if Self.isRecoverableVideoDecodeError(error) {
            recoverableDecodeFailureCount += 1
        } else if pendingPipelineError == nil {
            pendingPipelineError = Self.makePipelineError(error)
        }
    }

    private func throwPendingPipelineErrorIfNeeded() throws {
        guard let pendingPipelineError else {
            return
        }

        self.pendingPipelineError = nil
        throw pendingPipelineError
    }

    private static func makePipelineError(_ error: Error) -> MoonlightError {
        if let typed = error as? MoonlightError {
            return typed
        }

        return MoonlightError(.unsupportedOperation, message: String(describing: error))
    }

    private static func isRecoverableVideoDecodeError(_ error: Error) -> Bool {
        guard let typed = error as? MoonlightError else {
            return false
        }
        return typed.message.contains("VideoToolbox decode failed: -12909")
    }

    private func recordPacketTrace(
        packet: VideoTransportPacket,
        observedPacketIndex: Int,
        usedDecryptor: Bool,
        usedSyntheticSequenceNumber: Bool,
        encryptedByteCount: Int,
        rawByteCount: Int
    ) {
        guard packetTraceLimit > 0 else {
            return
        }

        let entry = VideoPacketTraceEntry(
            observedPacketIndex: observedPacketIndex,
            usedDecryptor: usedDecryptor,
            usedSyntheticSequenceNumber: usedSyntheticSequenceNumber,
            encryptedByteCount: encryptedByteCount,
            rawByteCount: rawByteCount,
            sequenceNumber: packet.rtp.sequenceNumber,
            packetType: packet.rtp.packetType,
            timestamp: packet.rtp.timestamp,
            streamPacketIndex: packet.video.streamPacketIndex,
            frameIndex: packet.video.frameIndex,
            flags: packet.video.flags,
            fecShardIndex: packet.video.fecShardIndex,
            dataShardCount: packet.video.dataShardCount,
            fecPercentage: packet.video.fecPercentage,
            fecBlockIndex: packet.video.fecBlockIndex,
            fecLastBlockIndex: packet.video.fecLastBlockIndex,
            isStartOfFrame: packet.video.isStartOfFrame,
            isEndOfFrame: packet.video.isEndOfFrame,
            isParityShard: packet.video.isParityShard
        )
        packetTrace.append(entry)
        if packetTrace.count > packetTraceLimit {
            packetTrace.removeFirst(packetTrace.count - packetTraceLimit)
        }
    }

    private func enrichVideoPacketError(
        _ error: Error,
        observedPacketCount: Int,
        usedDecryptor: Bool,
        packetData: Data,
        rawPacket: Data
    ) -> Error {
        let headerBytes = rawPacket.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
        let encryptedHeaderBytes = packetData.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
        let baseMessage: String
        if let typed = error as? MoonlightError {
            baseMessage = typed.message
        } else {
            baseMessage = error.localizedDescription
        }
        return MoonlightError(
            .invalidControlMessage,
            message: "\(baseMessage) [video packet #\(observedPacketCount), decrypted=\(usedDecryptor), encryptedLen=\(packetData.count), rawLen=\(rawPacket.count), encryptedPrefix=\(encryptedHeaderBytes), rawPrefix=\(headerBytes)]"
        )
    }
}

public actor AudioIngestService {
    private let source: MediaPacketSource
    private let decryptor: AudioPacketDecryptor?
    private let encryptionContext: AudioEncryptionContext?
    private let parser: AudioPacketParser
    private let depacketizer: SimpleAudioDepacketizer
    private let pipeline: MediaPipeline
    private var observedPacketCount = 0
    private var concealedPacketCount = 0

    public init(
        source: MediaPacketSource,
        decryptor: AudioPacketDecryptor? = nil,
        encryptionContext: AudioEncryptionContext? = nil,
        parser: AudioPacketParser = .init(),
        depacketizer: SimpleAudioDepacketizer = .init(),
        pipeline: MediaPipeline
    ) {
        self.source = source
        self.decryptor = decryptor
        self.encryptionContext = encryptionContext
        self.parser = parser
        self.depacketizer = depacketizer
        self.pipeline = pipeline
    }

    public func receiveNextPacket() async throws -> EncodedAudioPacket? {
        while let packetData = try await source.receivePacket() {
            observedPacketCount += 1
            let rawPacket: Data
            let usedDecryptor = decryptor != nil && encryptionContext != nil
            if let decryptor, let encryptionContext {
                rawPacket = try decryptor.decrypt(packetData, context: encryptionContext)
            } else {
                rawPacket = packetData
            }
            let packet: AudioTransportPacket
            do {
                packet = try parser.parse(rawPacket)
            } catch {
                let enriched = enrichAudioPacketError(
                    error,
                    observedPacketCount: observedPacketCount,
                    usedDecryptor: usedDecryptor,
                    packetData: packetData,
                    rawPacket: rawPacket
                )
                if let typed = enriched as? MoonlightError,
                   typed.code == .invalidControlMessage
                {
                    continue
                }
                throw enriched
            }
            if let encoded = try await depacketizer.submit(packet) {
                if encoded.isConcealment {
                    concealedPacketCount += 1
                }
                try await pipeline.ingestAudio(encoded)
                return encoded
            }
        }
        return nil
    }

    public func snapshotObservedPacketCount() -> Int {
        observedPacketCount
    }

    public func snapshotConcealedPacketCount() async -> Int {
        max(concealedPacketCount, await depacketizer.snapshotConcealedPacketCount())
    }

    public func snapshotReorderedPacketCount() async -> Int {
        await depacketizer.snapshotReorderedPacketCount()
    }

    public func snapshotMissingPacketCount() async -> Int {
        await depacketizer.snapshotMissingPacketCount()
    }

    private func enrichAudioPacketError(
        _ error: Error,
        observedPacketCount: Int,
        usedDecryptor: Bool,
        packetData: Data,
        rawPacket: Data
    ) -> Error {
        let headerBytes = rawPacket.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
        let encryptedHeaderBytes = packetData.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
        let payloadType = rawPacket.count >= 2 ? Int(rawPacket[1] & 0x7F) : -1
        let baseMessage: String
        if let typed = error as? MoonlightError {
            baseMessage = typed.message
        } else {
            baseMessage = error.localizedDescription
        }
        return MoonlightError(
            .invalidControlMessage,
            message: "\(baseMessage) [audio packet #\(observedPacketCount), decrypted=\(usedDecryptor), payloadType=\(payloadType), encryptedLen=\(packetData.count), rawLen=\(rawPacket.count), encryptedPrefix=\(encryptedHeaderBytes), rawPrefix=\(headerBytes)]"
        )
    }
}

private func readUInt16BE(_ data: Data, offset: Int) -> UInt16 {
    let b0 = UInt16(data[data.startIndex.advanced(by: offset)])
    let b1 = UInt16(data[data.startIndex.advanced(by: offset + 1)])
    return (b0 << 8) | b1
}

private func readUInt32BE(_ data: Data, offset: Int) -> UInt32 {
    let b0 = UInt32(data[data.startIndex.advanced(by: offset)])
    let b1 = UInt32(data[data.startIndex.advanced(by: offset + 1)])
    let b2 = UInt32(data[data.startIndex.advanced(by: offset + 2)])
    let b3 = UInt32(data[data.startIndex.advanced(by: offset + 3)])
    return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
}

private func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
    let b0 = UInt32(data[data.startIndex.advanced(by: offset)])
    let b1 = UInt32(data[data.startIndex.advanced(by: offset + 1)])
    let b2 = UInt32(data[data.startIndex.advanced(by: offset + 2)])
    let b3 = UInt32(data[data.startIndex.advanced(by: offset + 3)])
    return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
}

private func sequenceDistanceForward(from earlier: UInt16, to later: UInt16) -> Int {
    Int(later &- earlier)
}

private func fecBlockLowestSequenceNumber(for packet: VideoTransportPacket) -> UInt16 {
    packet.rtp.sequenceNumber &- packet.video.fecShardIndex
}

private func frameDistanceForward(from earlier: UInt32, to later: UInt32) -> UInt32 {
    later &- earlier
}

private func countMissingSequences(
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

private func isSequenceBehind(_ sequenceNumber: UInt16, relativeTo expectedSequenceNumber: UInt16) -> Bool {
    let delta = expectedSequenceNumber &- sequenceNumber
    return delta != 0 && delta < 0x8000
}

private struct ParsedRTPHeader {
    var rtp: RTPHeader
    var payloadOffset: Int
}

private func parseVideoPacketHeader(_ packet: Data) throws -> ParsedRTPHeader {
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
        let sequence = UInt16(truncatingIfNeeded: readUInt32LE(packet, offset: 0))
        let timestamp = readUInt32LE(packet, offset: 4)
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

private func isLikelyRTPv2(_ packet: Data) -> Bool {
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

private func parseRTPHeader(_ packet: Data) throws -> ParsedRTPHeader {
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

        let extensionLengthWords = Int(readUInt16BE(packet, offset: offset + 2))
        offset += 4 + (extensionLengthWords * 4)
        guard packet.count >= offset else {
            throw MoonlightError(.invalidControlMessage, message: "RTP extension payload is truncated")
        }
    }

    return ParsedRTPHeader(
        rtp: RTPHeader(
            hasExtension: hasExtension,
            packetType: packet[1] & 0x7F,
            sequenceNumber: readUInt16BE(packet, offset: 2),
            timestamp: readUInt32BE(packet, offset: 4),
            ssrc: readUInt32BE(packet, offset: 8)
        ),
        payloadOffset: offset
    )
}
