import Foundation
#if canImport(GameController)
import GameController
#endif
#if canImport(CoreHaptics)
import CoreHaptics
#endif

#if canImport(GameController)
public actor GameControllerFeedbackSink: ControllerFeedbackSink {
    #if canImport(CoreHaptics)
    private enum HapticMotorSlot: Hashable {
        case lowFrequencyHandle
        case highFrequencyHandle
        case leftTrigger
        case rightTrigger
    }

    private struct HapticMotorKey: Hashable {
        var controllerID: Int
        var slot: HapticMotorSlot
    }

    private var hapticMotors: [HapticMotorKey: GameControllerHapticMotor] = [:]
    #endif

    public init() {}

    public func apply(_ feedback: ControllerFeedback) async throws {
        guard let controller = Self.controller(matching: feedback.controllerID) else {
            return
        }

        switch feedback.effect {
        case .capabilities:
            break
        case .rumble(let lowFrequencyMotor, let highFrequencyMotor):
            try applyHandleRumble(
                lowFrequencyMotor: lowFrequencyMotor,
                highFrequencyMotor: highFrequencyMotor,
                to: controller,
                controllerID: feedback.controllerID
            )
        case .triggerRumble(let leftTriggerMotor, let rightTriggerMotor):
            try applyTriggerRumble(
                leftTriggerMotor: leftTriggerMotor,
                rightTriggerMotor: rightTriggerMotor,
                to: controller,
                controllerID: feedback.controllerID
            )
        case .motionReport(_, let reportRateHz):
            applyMotionReportRequest(reportRateHz: reportRateHz, to: controller)
        case .led(let red, let green, let blue):
            applyLED(red: red, green: green, blue: blue, to: controller)
        case .adaptiveTriggers(let eventFlags, let leftTriggerType, let rightTriggerType, _, _):
            applyAdaptiveTriggerMode(
                eventFlags: eventFlags,
                leftTriggerType: leftTriggerType,
                rightTriggerType: rightTriggerType,
                to: controller
            )
        }
    }

    private static func controller(matching controllerID: Int) -> GCController? {
        GCController.controllers().first { ObjectIdentifier($0).hashValue == controllerID }
    }

    private func applyHandleRumble(
        lowFrequencyMotor: UInt16,
        highFrequencyMotor: UInt16,
        to controller: GCController,
        controllerID: Int
    ) throws {
        #if canImport(CoreHaptics)
        try setHapticAmplitude(
            lowFrequencyMotor,
            slot: .lowFrequencyHandle,
            locality: .leftHandle,
            controller: controller,
            controllerID: controllerID
        )
        try setHapticAmplitude(
            highFrequencyMotor,
            slot: .highFrequencyHandle,
            locality: .rightHandle,
            controller: controller,
            controllerID: controllerID
        )
        #else
        _ = (lowFrequencyMotor, highFrequencyMotor, controller, controllerID)
        #endif
    }

    private func applyTriggerRumble(
        leftTriggerMotor: UInt16,
        rightTriggerMotor: UInt16,
        to controller: GCController,
        controllerID: Int
    ) throws {
        #if canImport(CoreHaptics)
        try setHapticAmplitude(
            leftTriggerMotor,
            slot: .leftTrigger,
            locality: .leftTrigger,
            controller: controller,
            controllerID: controllerID
        )
        try setHapticAmplitude(
            rightTriggerMotor,
            slot: .rightTrigger,
            locality: .rightTrigger,
            controller: controller,
            controllerID: controllerID
        )
        #else
        _ = (leftTriggerMotor, rightTriggerMotor, controller, controllerID)
        #endif
    }

    #if canImport(CoreHaptics)
    private func setHapticAmplitude(
        _ amplitude: UInt16,
        slot: HapticMotorSlot,
        locality: GCHapticsLocality,
        controller: GCController,
        controllerID: Int
    ) throws {
        let key = HapticMotorKey(controllerID: controllerID, slot: slot)
        if amplitude == 0 {
            try hapticMotors[key]?.setAmplitude(0)
            return
        }

        if let motor = hapticMotors[key] {
            try motor.setAmplitude(amplitude)
            return
        }

        guard let motor = try GameControllerHapticMotor(controller: controller, locality: locality) else {
            return
        }

        hapticMotors[key] = motor
        try motor.setAmplitude(amplitude)
    }
    #endif

    private func applyMotionReportRequest(reportRateHz: UInt16, to controller: GCController) {
        guard let motion = controller.motion, motion.sensorsRequireManualActivation else {
            return
        }

        motion.sensorsActive = reportRateHz > 0
    }

    private func applyLED(red: UInt8, green: UInt8, blue: UInt8, to controller: GCController) {
        guard let light = controller.light else {
            return
        }

        light.color = GCColor(
            red: Float(red) / 255,
            green: Float(green) / 255,
            blue: Float(blue) / 255
        )
    }

    private func applyAdaptiveTriggerMode(
        eventFlags: UInt8,
        leftTriggerType: UInt8,
        rightTriggerType: UInt8,
        to controller: GCController
    ) {
        guard #available(macOS 11.3, iOS 14.5, tvOS 14.5, *),
              let dualSense = controller.extendedGamepad as? GCDualSenseGamepad
        else {
            return
        }

        if eventFlags & AdaptiveTriggerUpdate.leftTriggerFlag != 0,
           Int(leftTriggerType) == GCDualSenseAdaptiveTrigger.Mode.off.rawValue
        {
            dualSense.leftTrigger.setModeOff()
        }
        if eventFlags & AdaptiveTriggerUpdate.rightTriggerFlag != 0,
           Int(rightTriggerType) == GCDualSenseAdaptiveTrigger.Mode.off.rawValue
        {
            dualSense.rightTrigger.setModeOff()
        }
    }
}

#if canImport(CoreHaptics)
private final class GameControllerHapticMotor {
    private let engine: CHHapticEngine
    private var player: (any CHHapticPatternPlayer)?
    private var isPlaying = false

    init?(controller: GCController, locality: GCHapticsLocality) throws {
        guard let haptics = controller.haptics,
              haptics.supportedLocalities.contains(locality),
              let engine = haptics.createEngine(withLocality: locality)
        else {
            return nil
        }

        self.engine = engine
        try engine.start()
    }

    func setAmplitude(_ amplitude: UInt16) throws {
        if amplitude == 0 {
            if isPlaying {
                try player?.stop(atTime: CHHapticTimeImmediate)
                isPlaying = false
            }
            return
        }

        if player == nil {
            player = try makePlayer()
        }

        let intensity = Float(amplitude) / Float(UInt16.max)
        let parameter = CHHapticDynamicParameter(
            parameterID: .hapticIntensityControl,
            value: intensity,
            relativeTime: 0
        )
        try player?.sendParameters([parameter], atTime: CHHapticTimeImmediate)

        if !isPlaying {
            try player?.start(atTime: CHHapticTimeImmediate)
            isPlaying = true
        }
    }

    private func makePlayer() throws -> any CHHapticPatternPlayer {
        let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 1)
        let event = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [intensity],
            relativeTime: 0,
            duration: TimeInterval(GCHapticDurationInfinite)
        )
        let pattern = try CHHapticPattern(events: [event], parameters: [])
        return try engine.makePlayer(with: pattern)
    }
}
#endif

public struct GameControllerSnapshotProvider: ControllerSnapshotProvider {
    public init() {}

    public func snapshots() async -> [ControllerSnapshot] {
        GCController.controllers().compactMap(Self.mapController)
    }

    private static func mapController(_ controller: GCController) -> ControllerSnapshot? {
        guard let gamepad = controller.extendedGamepad else {
            return nil
        }

        let id = ControllerID(rawValue: ObjectIdentifier(controller).hashValue)
        let kind = inferKind(controller, gamepad: gamepad)
        let battery = mapBattery(controller.battery, id: id)
        let motion = mapMotion(controller.motion, id: id)
        let descriptor = ControllerDescriptor(
            id: id,
            kind: kind,
            supportedButtons: supportedButtons(for: kind),
            supportsRumble: supportsRumble(for: kind),
            supportsTriggerRumble: supportsTriggerRumble(for: kind),
            supportsMotion: controller.motion != nil,
            supportsTouchpad: supportsTouchpad(for: kind),
            supportsBatteryState: battery != nil,
            supportsRGBLED: kind == .dualSense || kind == .dualShock
        )

        let state = ControllerState(
            id: id,
            buttons: pressedButtons(from: gamepad),
            leftStick: SIMD2<Float>(gamepad.leftThumbstick.xAxis.value, gamepad.leftThumbstick.yAxis.value),
            rightStick: SIMD2<Float>(gamepad.rightThumbstick.xAxis.value, gamepad.rightThumbstick.yAxis.value),
            leftTrigger: gamepad.leftTrigger.value,
            rightTrigger: gamepad.rightTrigger.value
        )

        return ControllerSnapshot(descriptor: descriptor, state: state, battery: battery, motion: motion)
    }

    private static func inferKind(_ controller: GCController, gamepad: GCExtendedGamepad) -> ControllerKind {
        if gamepad is GCDualSenseGamepad {
            return .dualSense
        }
        if gamepad is GCXboxGamepad {
            return .xbox
        }

        let name = [controller.vendorName, controller.productCategory]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        if name.contains("xbox") {
            return .xbox
        }
        if name.contains("dualsense") {
            return .dualSense
        }
        if name.contains("dualshock") {
            return .dualShock
        }
        return .extendedGamepad
    }

    private static func supportedButtons(for kind: ControllerKind) -> ControllerButtons {
        switch kind {
        case .dualSense, .dualShock:
            return [.standardGamepad, .touchpad]
        case .xbox:
            return [.standardGamepad, .misc]
        case .extendedGamepad, .unknown:
            return .standardGamepad
        }
    }

    private static func pressedButtons(from gamepad: GCExtendedGamepad) -> ControllerButtons {
        var buttons: ControllerButtons = []
        if gamepad.buttonA.isPressed { buttons.insert(.a) }
        if gamepad.buttonB.isPressed { buttons.insert(.b) }
        if gamepad.buttonX.isPressed { buttons.insert(.x) }
        if gamepad.buttonY.isPressed { buttons.insert(.y) }
        if gamepad.dpad.up.isPressed { buttons.insert(.dpadUp) }
        if gamepad.dpad.down.isPressed { buttons.insert(.dpadDown) }
        if gamepad.dpad.left.isPressed { buttons.insert(.dpadLeft) }
        if gamepad.dpad.right.isPressed { buttons.insert(.dpadRight) }
        if gamepad.leftShoulder.isPressed { buttons.insert(.leftShoulder) }
        if gamepad.rightShoulder.isPressed { buttons.insert(.rightShoulder) }
        if gamepad.leftThumbstickButton?.isPressed == true { buttons.insert(.leftStickPress) }
        if gamepad.rightThumbstickButton?.isPressed == true { buttons.insert(.rightStickPress) }
        if gamepad.buttonMenu.isPressed { buttons.insert(.start) }
        if gamepad.buttonOptions?.isPressed == true { buttons.insert(.back) }
        if gamepad.buttonHome?.isPressed == true { buttons.insert(.guide) }
        if let xbox = gamepad as? GCXboxGamepad, xbox.buttonShare?.isPressed == true {
            buttons.insert(.misc)
        }
        if let dualSense = gamepad as? GCDualSenseGamepad, dualSense.touchpadButton.isPressed {
            buttons.insert(.touchpad)
        }
        return buttons
    }

    private static func mapBattery(_ battery: GCDeviceBattery?, id: ControllerID) -> ControllerBattery? {
        guard let battery else {
            return nil
        }

        return ControllerBattery(
            id: id,
            state: batteryState(from: battery.batteryState),
            percentage: UInt8(clamping: Int((min(max(battery.batteryLevel, 0), 1) * 100).rounded()))
        )
    }

    private static func batteryState(from state: GCDeviceBattery.State) -> BatteryState {
        switch state {
        case .unknown:
            return .unknown
        case .discharging:
            return .discharging
        case .charging, .full:
            return .charging
        @unknown default:
            return .unknown
        }
    }

    private static func mapMotion(_ motion: GCMotion?, id: ControllerID) -> [ControllerMotion] {
        guard let motion else {
            return []
        }

        if motion.sensorsRequireManualActivation {
            motion.sensorsActive = true
        }

        var events: [ControllerMotion] = []
        let acceleration = motion.acceleration
        events.append(ControllerMotion(
            id: id,
            motionType: .accelerometer,
            x: Float(acceleration.x),
            y: Float(acceleration.y),
            z: Float(acceleration.z)
        ))

        if motion.hasRotationRate {
            let rotationRate = motion.rotationRate
            events.append(ControllerMotion(
                id: id,
                motionType: .gyroscope,
                x: Float(rotationRate.x),
                y: Float(rotationRate.y),
                z: Float(rotationRate.z)
            ))
        }
        return events
    }

    private static func supportsRumble(for kind: ControllerKind) -> Bool {
        switch kind {
        case .xbox, .dualSense, .dualShock:
            return true
        case .extendedGamepad, .unknown:
            return false
        }
    }

    private static func supportsTriggerRumble(for kind: ControllerKind) -> Bool {
        switch kind {
        case .xbox, .dualSense:
            return true
        case .dualShock, .extendedGamepad, .unknown:
            return false
        }
    }

    private static func supportsTouchpad(for kind: ControllerKind) -> Bool {
        switch kind {
        case .dualSense, .dualShock:
            return true
        case .xbox, .extendedGamepad, .unknown:
            return false
        }
    }
}
#endif
