import CoreGraphics
import Foundation

public struct PairingResult: Equatable, Sendable {
    public var hostID: HostID
    public var state: PairingState

    public init(hostID: HostID, state: PairingState) {
        self.hostID = hostID
        self.state = state
    }
}

public enum PairingAuth: Equatable, Sendable {
    case pin(String)
    case otp(pin: String, passphrase: String)

    public var pin: String {
        switch self {
        case .pin(let pin), .otp(let pin, _):
            return pin
        }
    }
}

public struct ClientIdentity: Equatable, Sendable {
    public var identifier: UUID
    public var displayName: String

    public init(identifier: UUID = UUID(), displayName: String = "swift-moonlight") {
        self.identifier = identifier
        self.displayName = displayName
    }
}
