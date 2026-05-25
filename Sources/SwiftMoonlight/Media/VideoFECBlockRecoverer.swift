import Foundation

enum VideoFECRecoveryError: Error, Equatable {
    case emptyBlock
    case invalidFECMetadata
    case mixedFECBlocks
    case invalidRecoveredPacket
}

struct VideoFECBlockRecoverer: Sendable {
    func recoverMissingDataPackets(from packets: [VideoTransportPacket]) throws -> [VideoTransportPacket] {
        guard let first = packets.first(where: { $0.video.dataShardCount > 0 }) else {
            throw VideoFECRecoveryError.emptyBlock
        }

        let dataShardCount = Int(first.video.dataShardCount)
        let parityShardCount = (dataShardCount * Int(first.video.fecPercentage) + 99) / 100
        guard dataShardCount > 0, parityShardCount > 0 else {
            throw VideoFECRecoveryError.invalidFECMetadata
        }

        let totalShardCount = dataShardCount + parityShardCount
        var baseSequenceNumber: UInt16?
        var shards = Array<Data?>(repeating: nil, count: totalShardCount)
        let blockIndex = first.video.fecBlockIndex
        let lastBlockIndex = first.video.fecLastBlockIndex

        for packet in packets where packet.video.dataShardCount > 0 {
            guard packet.video.frameIndex == first.video.frameIndex,
                  packet.video.dataShardCount == first.video.dataShardCount,
                  packet.video.fecPercentage == first.video.fecPercentage,
                  packet.video.fecBlockIndex == blockIndex,
                  packet.video.fecLastBlockIndex == lastBlockIndex
            else {
                throw VideoFECRecoveryError.mixedFECBlocks
            }

            let shardIndex = Int(packet.video.fecShardIndex)
            guard shardIndex >= 0, shardIndex < totalShardCount else {
                continue
            }

            let packetBaseSequence = packet.rtp.sequenceNumber &- UInt16(shardIndex)
            if let baseSequenceNumber {
                guard baseSequenceNumber == packetBaseSequence else {
                    throw VideoFECRecoveryError.mixedFECBlocks
                }
            } else {
                baseSequenceNumber = packetBaseSequence
            }

            shards[shardIndex] = packet.fecProtectedPayload
        }

        guard let baseSequenceNumber else {
            throw VideoFECRecoveryError.emptyBlock
        }

        let missingDataIndexes = (0..<dataShardCount).filter { shards[$0] == nil }
        guard !missingDataIndexes.isEmpty else {
            return []
        }

        let paddedShards = try padKnownShards(shards)
        let fec = try ReedSolomonFEC(dataShardCount: dataShardCount, parityShardCount: parityShardCount)
        let recoveredDataShards = try fec.recoverDataShards(from: paddedShards)
        let isFirstBlock = blockIndex == 0
        let isLastBlock = blockIndex == lastBlockIndex

        return try missingDataIndexes.map { dataIndex in
            let protectedPayload = recoveredDataShards[dataIndex]
            let video = try parseProtectedVideoHeader(protectedPayload)
            try validateRecoveredHeader(
                video,
                dataIndex: dataIndex,
                dataShardCount: dataShardCount,
                isFirstBlock: isFirstBlock,
                isLastBlock: isLastBlock
            )

            let payload = Data(protectedPayload.dropFirst(VideoPacketHeader.size))
            let rtp = RTPHeader(
                hasExtension: false,
                packetType: first.rtp.packetType,
                sequenceNumber: baseSequenceNumber &+ UInt16(dataIndex),
                timestamp: first.rtp.timestamp,
                ssrc: first.rtp.ssrc
            )
            return VideoTransportPacket(
                rtp: rtp,
                video: video,
                payload: payload,
                fecProtectedPayload: protectedPayload
            )
        }
    }

    private func padKnownShards(_ shards: [Data?]) throws -> [Data?] {
        let maxSize = shards.compactMap(\.?.count).max()
        guard let maxSize, maxSize >= VideoPacketHeader.size else {
            throw VideoFECRecoveryError.invalidFECMetadata
        }

        return shards.map { shard in
            guard var shard else {
                return nil
            }
            if shard.count < maxSize {
                shard.append(Data(repeating: 0, count: maxSize - shard.count))
            }
            return shard
        }
    }

    private func parseProtectedVideoHeader(_ data: Data) throws -> VideoPacketHeader {
        guard data.count >= VideoPacketHeader.size else {
            throw VideoFECRecoveryError.invalidRecoveredPacket
        }

        return VideoPacketHeader(
            streamPacketIndex: readUInt32LE(data, offset: 0),
            frameIndex: readUInt32LE(data, offset: 4),
            flags: data[data.startIndex + 8],
            extraFlags: data[data.startIndex + 9],
            multiFecFlags: data[data.startIndex + 10],
            multiFecBlocks: data[data.startIndex + 11],
            fecInfo: readUInt32LE(data, offset: 12)
        )
    }

    private func validateRecoveredHeader(
        _ video: VideoPacketHeader,
        dataIndex: Int,
        dataShardCount: Int,
        isFirstBlock: Bool,
        isLastBlock: Bool
    ) throws {
        guard video.hasKnownFlagBitsOnly else {
            throw VideoFECRecoveryError.invalidRecoveredPacket
        }
        if isFirstBlock, dataIndex == 0, video.flags & VideoPacketHeader.startOfFrameFlag == 0 {
            throw VideoFECRecoveryError.invalidRecoveredPacket
        }
        if isLastBlock, dataIndex == dataShardCount - 1, video.flags & VideoPacketHeader.endOfFrameFlag == 0 {
            throw VideoFECRecoveryError.invalidRecoveredPacket
        }
        if dataIndex > 0,
           dataIndex < dataShardCount - 1,
           video.flags & VideoPacketHeader.containsPictureDataFlag == 0
        {
            throw VideoFECRecoveryError.invalidRecoveredPacket
        }
    }
}

func makeFECProtectedPayload(video: VideoPacketHeader, payload: Data) -> Data {
    var data = Data()
    data.appendLE(video.streamPacketIndex)
    data.appendLE(video.frameIndex)
    data.append(video.flags)
    data.append(video.extraFlags)
    data.append(video.multiFecFlags)
    data.append(video.multiFecBlocks)
    data.appendLE(video.fecInfo)
    data.append(payload)
    return data
}

private extension Data {
    mutating func appendLE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}

private func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
    let b0 = UInt32(data[data.startIndex.advanced(by: offset)])
    let b1 = UInt32(data[data.startIndex.advanced(by: offset + 1)])
    let b2 = UInt32(data[data.startIndex.advanced(by: offset + 2)])
    let b3 = UInt32(data[data.startIndex.advanced(by: offset + 3)])
    return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
}
