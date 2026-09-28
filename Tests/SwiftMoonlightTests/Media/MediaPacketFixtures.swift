import CoreGraphics
import Foundation
import Testing
@testable import SwiftMoonlight
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

func makeVideoPacket(
    sequenceNumber: UInt16,
    timestamp: UInt32,
    streamPacketIndex: UInt32,
    frameIndex: UInt32,
    flags: UInt8,
    extraFlags: UInt8 = 0,
    multiFecFlags: UInt8 = 0,
    multiFecBlocks: UInt8 = 0,
    fecInfo: UInt32 = 0,
    payload: Data,
    rtpExtensionWords: [UInt32]? = nil
) -> Data {
    var data = Data()
    data.append(rtpExtensionWords == nil ? 0x80 : 0x90)
    data.append(0x60)
    data.append(UInt8(truncatingIfNeeded: sequenceNumber >> 8))
    data.append(UInt8(truncatingIfNeeded: sequenceNumber))
    data.append(contentsOf: [
        UInt8(truncatingIfNeeded: timestamp >> 24),
        UInt8(truncatingIfNeeded: timestamp >> 16),
        UInt8(truncatingIfNeeded: timestamp >> 8),
        UInt8(truncatingIfNeeded: timestamp)
    ])
    data.append(contentsOf: [0,0,0,1])
    if let rtpExtensionWords {
        data.append(contentsOf: [0xBE, 0xDE])
        let length = UInt16(rtpExtensionWords.count)
        data.append(UInt8(truncatingIfNeeded: length >> 8))
        data.append(UInt8(truncatingIfNeeded: length))
        for word in rtpExtensionWords {
            data.append(contentsOf: [
                UInt8(truncatingIfNeeded: word >> 24),
                UInt8(truncatingIfNeeded: word >> 16),
                UInt8(truncatingIfNeeded: word >> 8),
                UInt8(truncatingIfNeeded: word)
            ])
        }
    }
    data.append(contentsOf: [
        UInt8(truncatingIfNeeded: streamPacketIndex),
        UInt8(truncatingIfNeeded: streamPacketIndex >> 8),
        UInt8(truncatingIfNeeded: streamPacketIndex >> 16),
        UInt8(truncatingIfNeeded: streamPacketIndex >> 24),
        UInt8(truncatingIfNeeded: frameIndex),
        UInt8(truncatingIfNeeded: frameIndex >> 8),
        UInt8(truncatingIfNeeded: frameIndex >> 16),
        UInt8(truncatingIfNeeded: frameIndex >> 24),
        flags,
        extraFlags,
        multiFecFlags,
        multiFecBlocks,
        UInt8(truncatingIfNeeded: fecInfo),
        UInt8(truncatingIfNeeded: fecInfo >> 8),
        UInt8(truncatingIfNeeded: fecInfo >> 16),
        UInt8(truncatingIfNeeded: fecInfo >> 24)
    ])
    data.append(payload)
    return data
}

func makeBareVideoPacket(
    streamPacketIndex: UInt32,
    frameIndex: UInt32,
    flags: UInt8,
    extraFlags: UInt8 = 0,
    multiFecFlags: UInt8 = 0,
    multiFecBlocks: UInt8 = 0,
    fecInfo: UInt32 = 0,
    payload: Data
) -> Data {
    var data = Data()
    data.append(contentsOf: [
        UInt8(truncatingIfNeeded: streamPacketIndex),
        UInt8(truncatingIfNeeded: streamPacketIndex >> 8),
        UInt8(truncatingIfNeeded: streamPacketIndex >> 16),
        UInt8(truncatingIfNeeded: streamPacketIndex >> 24),
        UInt8(truncatingIfNeeded: frameIndex),
        UInt8(truncatingIfNeeded: frameIndex >> 8),
        UInt8(truncatingIfNeeded: frameIndex >> 16),
        UInt8(truncatingIfNeeded: frameIndex >> 24),
        flags,
        extraFlags,
        multiFecFlags,
        multiFecBlocks,
        UInt8(truncatingIfNeeded: fecInfo),
        UInt8(truncatingIfNeeded: fecInfo >> 8),
        UInt8(truncatingIfNeeded: fecInfo >> 16),
        UInt8(truncatingIfNeeded: fecInfo >> 24)
    ])
    data.append(payload)
    return data
}

func makeVideoParityPackets(
    _ parityShards: [Data],
    baseSequenceNumber: UInt16,
    timestamp: UInt32,
    frameIndex: UInt32,
    dataShardCount: UInt32,
    fecPercentage: UInt32
) -> [VideoTransportPacket] {
    parityShards.enumerated().map { parityIndex, protectedPayload in
        let shardIndex = dataShardCount + UInt32(parityIndex)
        let video = VideoPacketHeader(
            streamPacketIndex: shardIndex + 1,
            frameIndex: frameIndex,
            flags: 0,
            extraFlags: 0,
            multiFecFlags: 0,
            multiFecBlocks: 0,
            fecInfo: (dataShardCount << 22) | (shardIndex << 12) | (fecPercentage << 4)
        )
        return VideoTransportPacket(
            rtp: RTPHeader(
                packetType: 0x60,
                sequenceNumber: baseSequenceNumber &+ UInt16(shardIndex),
                timestamp: timestamp,
                ssrc: 1
            ),
            video: video,
            payload: Data(),
            fecProtectedPayload: protectedPayload
        )
    }
}

func makeAudioPacket(
    sequenceNumber: UInt16,
    timestamp: UInt32,
    payloadType: UInt8 = AudioTransportPacket.opusPayloadType,
    payload: Data
) -> Data {
    var data = Data()
    data.append(0x80)
    data.append(payloadType | 0x80)
    data.append(UInt8(truncatingIfNeeded: sequenceNumber >> 8))
    data.append(UInt8(truncatingIfNeeded: sequenceNumber))
    data.append(contentsOf: [
        UInt8(truncatingIfNeeded: timestamp >> 24),
        UInt8(truncatingIfNeeded: timestamp >> 16),
        UInt8(truncatingIfNeeded: timestamp >> 8),
        UInt8(truncatingIfNeeded: timestamp)
    ])
    data.append(contentsOf: [0,0,0,2])
    data.append(payload)
    return data
}
