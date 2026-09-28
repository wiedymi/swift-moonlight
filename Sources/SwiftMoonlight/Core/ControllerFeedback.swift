import CoreGraphics
import Foundation

public enum ControllerFeedbackEffect: Sendable, Equatable {
    case capabilities(supportsRumble: Bool)
    case rumble(lowFrequencyMotor: UInt16, highFrequencyMotor: UInt16)
    case triggerRumble(leftTriggerMotor: UInt16, rightTriggerMotor: UInt16)
    case motionReport(motionType: UInt8, reportRateHz: UInt16)
    case led(red: UInt8, green: UInt8, blue: UInt8)
    case adaptiveTriggers(
        eventFlags: UInt8,
        leftTriggerType: UInt8,
        rightTriggerType: UInt8,
        leftPayload: [UInt8],
        rightPayload: [UInt8]
    )

    public var requestsRumble: Bool {
        switch self {
        case .capabilities(let supportsRumble):
            supportsRumble
        case .rumble, .triggerRumble:
            true
        case .motionReport, .led, .adaptiveTriggers:
            false
        }
    }
}

public struct ControllerFeedback: Sendable, Equatable {
    public var controllerID: Int
    public var supportsRumble: Bool
    public var effect: ControllerFeedbackEffect

    public init(controllerID: Int, supportsRumble: Bool) {
        self.controllerID = controllerID
        self.supportsRumble = supportsRumble
        self.effect = .capabilities(supportsRumble: supportsRumble)
    }

    public init(controllerID: Int, effect: ControllerFeedbackEffect) {
        self.controllerID = controllerID
        self.supportsRumble = effect.requestsRumble
        self.effect = effect
    }
}

public protocol ControllerFeedbackSink: Sendable {
    func apply(_ feedback: ControllerFeedback) async throws
}
