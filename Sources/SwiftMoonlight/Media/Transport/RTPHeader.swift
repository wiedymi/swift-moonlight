import Foundation

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
