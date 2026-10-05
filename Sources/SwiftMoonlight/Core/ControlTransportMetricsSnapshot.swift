import Foundation

public struct ControlTransportMetricsSnapshot: Equatable, Sendable, Codable {
    public var isConnected: Bool
    public var roundTripTimeMs: Int?
    public var roundTripTimeVarianceMs: Int?
    public var packetLossRatio: Double?
    public var packetLossVarianceRatio: Double?

    public init(
        isConnected: Bool = false,
        roundTripTimeMs: Int? = nil,
        roundTripTimeVarianceMs: Int? = nil,
        packetLossRatio: Double? = nil,
        packetLossVarianceRatio: Double? = nil
    ) {
        self.isConnected = isConnected
        self.roundTripTimeMs = roundTripTimeMs
        self.roundTripTimeVarianceMs = roundTripTimeVarianceMs
        self.packetLossRatio = packetLossRatio
        self.packetLossVarianceRatio = packetLossVarianceRatio
    }
}
