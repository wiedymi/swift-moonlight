import Foundation

public struct MoonlightError: Error, Equatable, Sendable {
    public let code: Code
    public let message: String

    public init(_ code: Code, message: String) {
        self.code = code
        self.message = message
    }

    public enum Code: String, Sendable {
        case hostNotFound
        case hostNotPaired
        case networkRequestFailed
        case invalidStateTransition
        case pairingRejected
        case capabilityMismatch
        case launchRejected
        case invalidLaunchResponse
        case invalidControlMessage
        case unsupportedOperation
    }
}
