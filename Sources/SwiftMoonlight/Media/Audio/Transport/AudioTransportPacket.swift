import Foundation

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
