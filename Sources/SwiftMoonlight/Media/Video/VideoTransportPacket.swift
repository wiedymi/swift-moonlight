import Foundation

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
