import Foundation
import simd

public enum InputEvent: Sendable {
    case mouse(MouseEvent)
    case keyboard(KeyboardEvent)
    case touch(TouchEvent)
    case pen(PenEvent)
    case controller(ControllerEvent)
}

public enum MouseButton: Sendable {
    case left
    case middle
    case right
    case x1
    case x2
}

public enum ButtonState: Sendable {
    case pressed
    case released
}

public enum MouseEvent: Sendable {
    case relativeMove(dx: Int16, dy: Int16)
    case absoluteMove(x: Double, y: Double)
    case button(button: MouseButton, state: ButtonState)
    case verticalScroll(delta: Int16)
    case horizontalScroll(delta: Int16)
}

public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let alt = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
}

public struct KeyCode: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let backspace = KeyCode(rawValue: 0x08)
    public static let tab = KeyCode(rawValue: 0x09)
    public static let clear = KeyCode(rawValue: 0x0C)
    public static let enter = KeyCode(rawValue: 0x0D)
    public static let shift = KeyCode(rawValue: 0x10)
    public static let control = KeyCode(rawValue: 0x11)
    public static let alt = KeyCode(rawValue: 0x12)
    public static let pause = KeyCode(rawValue: 0x13)
    public static let capsLock = KeyCode(rawValue: 0x14)
    public static let escape = KeyCode(rawValue: 0x1B)
    public static let space = KeyCode(rawValue: 0x20)
    public static let pageUp = KeyCode(rawValue: 0x21)
    public static let pageDown = KeyCode(rawValue: 0x22)
    public static let end = KeyCode(rawValue: 0x23)
    public static let home = KeyCode(rawValue: 0x24)
    public static let leftArrow = KeyCode(rawValue: 0x25)
    public static let upArrow = KeyCode(rawValue: 0x26)
    public static let rightArrow = KeyCode(rawValue: 0x27)
    public static let downArrow = KeyCode(rawValue: 0x28)
    public static let insert = KeyCode(rawValue: 0x2D)
    public static let delete = KeyCode(rawValue: 0x2E)
    public static let help = KeyCode(rawValue: 0x2F)

    public static let digit0 = KeyCode(rawValue: 0x30)
    public static let digit1 = KeyCode(rawValue: 0x31)
    public static let digit2 = KeyCode(rawValue: 0x32)
    public static let digit3 = KeyCode(rawValue: 0x33)
    public static let digit4 = KeyCode(rawValue: 0x34)
    public static let digit5 = KeyCode(rawValue: 0x35)
    public static let digit6 = KeyCode(rawValue: 0x36)
    public static let digit7 = KeyCode(rawValue: 0x37)
    public static let digit8 = KeyCode(rawValue: 0x38)
    public static let digit9 = KeyCode(rawValue: 0x39)

    public static let a = KeyCode(rawValue: 0x41)
    public static let b = KeyCode(rawValue: 0x42)
    public static let c = KeyCode(rawValue: 0x43)
    public static let d = KeyCode(rawValue: 0x44)
    public static let e = KeyCode(rawValue: 0x45)
    public static let f = KeyCode(rawValue: 0x46)
    public static let g = KeyCode(rawValue: 0x47)
    public static let h = KeyCode(rawValue: 0x48)
    public static let i = KeyCode(rawValue: 0x49)
    public static let j = KeyCode(rawValue: 0x4A)
    public static let k = KeyCode(rawValue: 0x4B)
    public static let l = KeyCode(rawValue: 0x4C)
    public static let m = KeyCode(rawValue: 0x4D)
    public static let n = KeyCode(rawValue: 0x4E)
    public static let o = KeyCode(rawValue: 0x4F)
    public static let p = KeyCode(rawValue: 0x50)
    public static let q = KeyCode(rawValue: 0x51)
    public static let r = KeyCode(rawValue: 0x52)
    public static let s = KeyCode(rawValue: 0x53)
    public static let t = KeyCode(rawValue: 0x54)
    public static let u = KeyCode(rawValue: 0x55)
    public static let v = KeyCode(rawValue: 0x56)
    public static let w = KeyCode(rawValue: 0x57)
    public static let x = KeyCode(rawValue: 0x58)
    public static let y = KeyCode(rawValue: 0x59)
    public static let z = KeyCode(rawValue: 0x5A)

    public static let leftCommand = KeyCode(rawValue: 0x5B)
    public static let rightCommand = KeyCode(rawValue: 0x5C)
    public static let contextMenu = KeyCode(rawValue: 0x5D)

    public static let keypad0 = KeyCode(rawValue: 0x60)
    public static let keypad1 = KeyCode(rawValue: 0x61)
    public static let keypad2 = KeyCode(rawValue: 0x62)
    public static let keypad3 = KeyCode(rawValue: 0x63)
    public static let keypad4 = KeyCode(rawValue: 0x64)
    public static let keypad5 = KeyCode(rawValue: 0x65)
    public static let keypad6 = KeyCode(rawValue: 0x66)
    public static let keypad7 = KeyCode(rawValue: 0x67)
    public static let keypad8 = KeyCode(rawValue: 0x68)
    public static let keypad9 = KeyCode(rawValue: 0x69)
    public static let keypadMultiply = KeyCode(rawValue: 0x6A)
    public static let keypadAdd = KeyCode(rawValue: 0x6B)
    public static let keypadSubtract = KeyCode(rawValue: 0x6D)
    public static let keypadDecimal = KeyCode(rawValue: 0x6E)
    public static let keypadDivide = KeyCode(rawValue: 0x6F)

    public static let f1 = KeyCode(rawValue: 0x70)
    public static let f2 = KeyCode(rawValue: 0x71)
    public static let f3 = KeyCode(rawValue: 0x72)
    public static let f4 = KeyCode(rawValue: 0x73)
    public static let f5 = KeyCode(rawValue: 0x74)
    public static let f6 = KeyCode(rawValue: 0x75)
    public static let f7 = KeyCode(rawValue: 0x76)
    public static let f8 = KeyCode(rawValue: 0x77)
    public static let f9 = KeyCode(rawValue: 0x78)
    public static let f10 = KeyCode(rawValue: 0x79)
    public static let f11 = KeyCode(rawValue: 0x7A)
    public static let f12 = KeyCode(rawValue: 0x7B)
    public static let f13 = KeyCode(rawValue: 0x7C)
    public static let f14 = KeyCode(rawValue: 0x7D)
    public static let f15 = KeyCode(rawValue: 0x7E)
    public static let f16 = KeyCode(rawValue: 0x7F)
    public static let f17 = KeyCode(rawValue: 0x80)
    public static let f18 = KeyCode(rawValue: 0x81)
    public static let f19 = KeyCode(rawValue: 0x82)
    public static let f20 = KeyCode(rawValue: 0x83)

    public static let leftShift = KeyCode(rawValue: 0xA0)
    public static let rightShift = KeyCode(rawValue: 0xA1)
    public static let leftControl = KeyCode(rawValue: 0xA2)
    public static let rightControl = KeyCode(rawValue: 0xA3)
    public static let leftAlt = KeyCode(rawValue: 0xA4)
    public static let rightAlt = KeyCode(rawValue: 0xA5)

    public static let semicolon = KeyCode(rawValue: 0xBA)
    public static let equal = KeyCode(rawValue: 0xBB)
    public static let comma = KeyCode(rawValue: 0xBC)
    public static let minus = KeyCode(rawValue: 0xBD)
    public static let period = KeyCode(rawValue: 0xBE)
    public static let slash = KeyCode(rawValue: 0xBF)
    public static let backtick = KeyCode(rawValue: 0xC0)
    public static let leftBracket = KeyCode(rawValue: 0xDB)
    public static let backslash = KeyCode(rawValue: 0xDC)
    public static let rightBracket = KeyCode(rawValue: 0xDD)
    public static let quote = KeyCode(rawValue: 0xDE)
}

public enum KeyboardEvent: Sendable {
    case keyDown(KeyCode, modifiers: KeyModifiers = [])
    case keyUp(KeyCode, modifiers: KeyModifiers = [])
    case text(String)
}

public enum TouchPhase: Sendable {
    case hovering
    case began
    case moved
    case ended
    case cancelled
    case hoverEnded
    case cancelledAll
}

public struct TouchContact: Sendable {
    public var id: Int
    public var phase: TouchPhase
    public var x: Double
    public var y: Double
    public var pressure: Double
    public var rotation: Int16
    public var contactAreaMajor: Double
    public var contactAreaMinor: Double

    public init(
        id: Int,
        phase: TouchPhase,
        x: Double,
        y: Double,
        pressure: Double = 0,
        rotation: Int16 = -1,
        contactAreaMajor: Double = 0,
        contactAreaMinor: Double = 0
    ) {
        self.id = id
        self.phase = phase
        self.x = x
        self.y = y
        self.pressure = pressure
        self.rotation = rotation
        self.contactAreaMajor = contactAreaMajor
        self.contactAreaMinor = contactAreaMinor
    }
}

public struct TouchEvent: Sendable {
    public var contacts: [TouchContact]

    public init(contacts: [TouchContact]) {
        self.contacts = contacts
    }
}

public enum PenToolType: UInt8, Sendable {
    case unknown = 0x00
    case pen = 0x01
    case eraser = 0x02
}

public struct PenButtons: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let primary = PenButtons(rawValue: 1 << 0)
    public static let secondary = PenButtons(rawValue: 1 << 1)
    public static let tertiary = PenButtons(rawValue: 1 << 2)
}

public struct PenContact: Sendable {
    public var phase: TouchPhase
    public var toolType: PenToolType
    public var buttons: PenButtons
    public var x: Double
    public var y: Double
    public var pressure: Double
    public var rotation: Int16
    public var tilt: UInt8
    public var contactAreaMajor: Double
    public var contactAreaMinor: Double

    public init(
        phase: TouchPhase,
        toolType: PenToolType = .pen,
        buttons: PenButtons = [],
        x: Double,
        y: Double,
        pressure: Double = 0,
        rotation: Int16 = 0,
        tilt: UInt8 = 0,
        contactAreaMajor: Double = 0,
        contactAreaMinor: Double = 0
    ) {
        self.phase = phase
        self.toolType = toolType
        self.buttons = buttons
        self.x = x
        self.y = y
        self.pressure = pressure
        self.rotation = rotation
        self.tilt = tilt
        self.contactAreaMajor = contactAreaMajor
        self.contactAreaMinor = contactAreaMinor
    }
}

public struct PenEvent: Sendable {
    public var contact: PenContact

    public init(contact: PenContact) {
        self.contact = contact
    }
}

public struct ControllerID: Hashable, Sendable {
    public var rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

public enum ControllerKind: Sendable, Equatable {
    case xbox
    case dualSense
    case dualShock
    case extendedGamepad
    case unknown
}

public struct ControllerDescriptor: Sendable, Equatable {
    public var id: ControllerID
    public var kind: ControllerKind
    public var supportedButtons: ControllerButtons
    public var supportsRumble: Bool
    public var supportsTriggerRumble: Bool
    public var supportsMotion: Bool
    public var supportsTouchpad: Bool
    public var supportsBatteryState: Bool
    public var supportsRGBLED: Bool

    public init(
        id: ControllerID,
        kind: ControllerKind,
        supportedButtons: ControllerButtons = .standardGamepad,
        supportsRumble: Bool,
        supportsTriggerRumble: Bool,
        supportsMotion: Bool,
        supportsTouchpad: Bool,
        supportsBatteryState: Bool = false,
        supportsRGBLED: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.supportedButtons = supportedButtons
        self.supportsRumble = supportsRumble
        self.supportsTriggerRumble = supportsTriggerRumble
        self.supportsMotion = supportsMotion
        self.supportsTouchpad = supportsTouchpad
        self.supportsBatteryState = supportsBatteryState
        self.supportsRGBLED = supportsRGBLED
    }
}

public struct ControllerButtons: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let dpadUp = ControllerButtons(rawValue: 1 << 4)
    public static let dpadDown = ControllerButtons(rawValue: 1 << 5)
    public static let dpadLeft = ControllerButtons(rawValue: 1 << 6)
    public static let dpadRight = ControllerButtons(rawValue: 1 << 7)
    public static let leftShoulder = ControllerButtons(rawValue: 1 << 8)
    public static let rightShoulder = ControllerButtons(rawValue: 1 << 9)
    public static let start = ControllerButtons(rawValue: 1 << 10)
    public static let back = ControllerButtons(rawValue: 1 << 11)
    public static let leftStickPress = ControllerButtons(rawValue: 1 << 12)
    public static let rightStickPress = ControllerButtons(rawValue: 1 << 13)
    public static let guide = ControllerButtons(rawValue: 1 << 14)
    public static let paddle1 = ControllerButtons(rawValue: 1 << 15)
    public static let paddle2 = ControllerButtons(rawValue: 1 << 16)
    public static let paddle3 = ControllerButtons(rawValue: 1 << 17)
    public static let paddle4 = ControllerButtons(rawValue: 1 << 18)
    public static let touchpad = ControllerButtons(rawValue: 1 << 19)
    public static let misc = ControllerButtons(rawValue: 1 << 20)

    public static let standardGamepad: ControllerButtons = [
        .a, .b, .x, .y,
        .dpadUp, .dpadDown, .dpadLeft, .dpadRight,
        .leftShoulder, .rightShoulder,
        .start, .back,
        .leftStickPress, .rightStickPress,
        .guide
    ]

    public static let a = ControllerButtons(rawValue: 1 << 0)
    public static let b = ControllerButtons(rawValue: 1 << 1)
    public static let x = ControllerButtons(rawValue: 1 << 2)
    public static let y = ControllerButtons(rawValue: 1 << 3)
}

public struct ControllerState: Sendable, Equatable {
    public var id: ControllerID
    public var buttons: ControllerButtons
    public var leftStick: SIMD2<Float>
    public var rightStick: SIMD2<Float>
    public var leftTrigger: Float
    public var rightTrigger: Float

    public init(
        id: ControllerID,
        buttons: ControllerButtons,
        leftStick: SIMD2<Float>,
        rightStick: SIMD2<Float>,
        leftTrigger: Float,
        rightTrigger: Float
    ) {
        self.id = id
        self.buttons = buttons
        self.leftStick = leftStick
        self.rightStick = rightStick
        self.leftTrigger = leftTrigger
        self.rightTrigger = rightTrigger
    }
}

public struct ControllerBattery: Sendable, Equatable {
    public var id: ControllerID
    public var state: BatteryState
    public var percentage: UInt8

    public init(id: ControllerID, state: BatteryState = .unknown, percentage: UInt8) {
        self.id = id
        self.state = state
        self.percentage = percentage
    }
}

public enum MotionType: UInt8, Sendable, Equatable {
    case accelerometer = 0x01
    case gyroscope = 0x02
}

public struct ControllerMotion: Sendable, Equatable {
    public var id: ControllerID
    public var motionType: MotionType
    public var x: Float
    public var y: Float
    public var z: Float

    public init(id: ControllerID, motionType: MotionType, x: Float, y: Float, z: Float) {
        self.id = id
        self.motionType = motionType
        self.x = x
        self.y = y
        self.z = z
    }
}

public struct ControllerTouchpadEvent: Sendable, Equatable {
    public var id: ControllerID
    public var phase: TouchPhase
    public var pointerID: UInt32
    public var x: Double
    public var y: Double
    public var pressure: Double

    public init(
        id: ControllerID,
        phase: TouchPhase,
        pointerID: UInt32,
        x: Double,
        y: Double,
        pressure: Double = 0
    ) {
        self.id = id
        self.phase = phase
        self.pointerID = pointerID
        self.x = x
        self.y = y
        self.pressure = pressure
    }
}

public enum BatteryState: UInt8, Sendable, Equatable {
    case unknown = 0x00
    case notPresent = 0x01
    case discharging = 0x02
    case charging = 0x03
    case notCharging = 0x04
    case full = 0x05
}

public enum ControllerEvent: Sendable, Equatable {
    case connected(ControllerDescriptor)
    case disconnected(ControllerID)
    case stateChanged(ControllerState)
    case battery(ControllerBattery)
    case motion(ControllerMotion)
    case touchpad(ControllerTouchpadEvent)
}
