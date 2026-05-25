#if os(macOS)
import AppKit
import Carbon.HIToolbox
import SwiftMoonlight

public struct TestAppSurfaceInputState: Sendable {
    private var activeModifierKeyCodes: Set<UInt16> = []
    private var activeKeyboardKeyCodes: Set<UInt16> = []
    private var activeMouseButtonNumbers: Set<Int> = []

    public init() {}

    public func isMouseButtonPressed(_ buttonNumber: Int) -> Bool {
        activeMouseButtonNumbers.contains(buttonNumber)
    }

    public mutating func keyDown(
        macKeyCode: UInt16,
        isRepeat: Bool,
        modifierFlags: NSEvent.ModifierFlags
    ) -> InputEvent? {
        guard !isRepeat,
              let keyCode = TestAppSurfaceInputMapper.keyCode(for: macKeyCode),
              activeKeyboardKeyCodes.insert(macKeyCode).inserted
        else {
            return nil
        }

        return .keyboard(.keyDown(keyCode, modifiers: TestAppSurfaceInputMapper.modifiers(for: modifierFlags)))
    }

    public mutating func keyUp(
        macKeyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> InputEvent? {
        guard let keyCode = TestAppSurfaceInputMapper.keyCode(for: macKeyCode),
              activeKeyboardKeyCodes.remove(macKeyCode) != nil
        else {
            return nil
        }

        return .keyboard(.keyUp(keyCode, modifiers: TestAppSurfaceInputMapper.modifiers(for: modifierFlags)))
    }

    public mutating func modifierChanged(macKeyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> InputEvent? {
        guard let keyCode = TestAppSurfaceInputMapper.keyCode(for: macKeyCode) else {
            return nil
        }

        let isTracked = activeModifierKeyCodes.contains(macKeyCode)
        let isPressed = TestAppSurfaceInputMapper.modifierIsPressed(macKeyCode: macKeyCode, flags: modifierFlags)
        if isPressed && !isTracked {
            activeModifierKeyCodes.insert(macKeyCode)
            return .keyboard(.keyDown(keyCode, modifiers: TestAppSurfaceInputMapper.modifiers(for: modifierFlags)))
        }
        if !isPressed && isTracked {
            activeModifierKeyCodes.remove(macKeyCode)
            return .keyboard(.keyUp(keyCode, modifiers: TestAppSurfaceInputMapper.modifiers(for: modifierFlags)))
        }

        return nil
    }

    public mutating func pressMouseButton(_ button: MouseButton, buttonNumber: Int) -> InputEvent? {
        guard activeMouseButtonNumbers.insert(buttonNumber).inserted else {
            return nil
        }

        return .mouse(.button(button: button, state: .pressed))
    }

    public mutating func releaseMouseButton(_ button: MouseButton, buttonNumber: Int) -> InputEvent? {
        guard activeMouseButtonNumbers.remove(buttonNumber) != nil else {
            return nil
        }

        return .mouse(.button(button: button, state: .released))
    }

    public mutating func releaseTrackedInput() -> [InputEvent] {
        var events: [InputEvent] = []
        events.append(contentsOf: releaseTrackedMouseButtons())
        events.append(contentsOf: releaseTrackedKeys())
        events.append(contentsOf: releaseTrackedModifiers())
        return events
    }

    private mutating func releaseTrackedMouseButtons() -> [InputEvent] {
        guard !activeMouseButtonNumbers.isEmpty else { return [] }

        let trackedButtonNumbers = activeMouseButtonNumbers
        activeMouseButtonNumbers.removeAll()

        return trackedButtonNumbers.sorted().compactMap { buttonNumber in
            guard let button = TestAppSurfaceInputMapper.mouseButton(for: buttonNumber) else {
                return nil
            }
            return .mouse(.button(button: button, state: .released))
        }
    }

    private mutating func releaseTrackedKeys() -> [InputEvent] {
        guard !activeKeyboardKeyCodes.isEmpty else { return [] }

        let trackedKeyCodes = activeKeyboardKeyCodes
        activeKeyboardKeyCodes.removeAll()

        return trackedKeyCodes.sorted().compactMap { keyCode in
            guard let mapped = TestAppSurfaceInputMapper.keyCode(for: keyCode) else {
                return nil
            }
            return .keyboard(.keyUp(mapped))
        }
    }

    private mutating func releaseTrackedModifiers() -> [InputEvent] {
        guard !activeModifierKeyCodes.isEmpty else { return [] }

        let trackedKeyCodes = activeModifierKeyCodes
        activeModifierKeyCodes.removeAll()

        return trackedKeyCodes.sorted().compactMap { keyCode in
            guard let mapped = TestAppSurfaceInputMapper.keyCode(for: keyCode) else {
                return nil
            }
            return .keyboard(.keyUp(mapped))
        }
    }
}

public enum TestAppSurfaceInputMapper {
    public static func modifierIsPressed(macKeyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        switch Int(macKeyCode) {
        case kVK_Command:
            return containsRawModifierMask(0x00000008, in: flags)
        case kVK_RightCommand:
            return containsRawModifierMask(0x00000010, in: flags)
        case kVK_Shift:
            return containsRawModifierMask(0x00000002, in: flags)
        case kVK_RightShift:
            return containsRawModifierMask(0x00000004, in: flags)
        case kVK_Control:
            return containsRawModifierMask(0x00000001, in: flags)
        case kVK_RightControl:
            return containsRawModifierMask(0x00002000, in: flags)
        case kVK_Option:
            return containsRawModifierMask(0x00000020, in: flags)
        case kVK_RightOption:
            return containsRawModifierMask(0x00000040, in: flags)
        case kVK_CapsLock:
            return flags.contains(.capsLock)
        default:
            return false
        }
    }

    public static func modifiers(for flags: NSEvent.ModifierFlags) -> KeyModifiers {
        let filteredFlags = flags.intersection(.deviceIndependentFlagsMask)
        var modifiers: KeyModifiers = []
        if filteredFlags.contains(.shift) {
            modifiers.insert(.shift)
        }
        if filteredFlags.contains(.control) {
            modifiers.insert(.control)
        }
        if filteredFlags.contains(.option) {
            modifiers.insert(.alt)
        }
        if filteredFlags.contains(.command) {
            modifiers.insert(.command)
        }
        return modifiers
    }

    public static func mouseButton(for buttonNumber: Int) -> MouseButton? {
        switch buttonNumber {
        case 0:
            return .left
        case 1:
            return .right
        case 2:
            return .middle
        case 3:
            return .x1
        case 4:
            return .x2
        default:
            return nil
        }
    }

    public static func relativePointerDelta(appKitDeltaX: CGFloat, appKitDeltaY: CGFloat) -> (x: Double, y: Double) {
        (Double(appKitDeltaX), Double(appKitDeltaY))
    }

    public static func keyCode(for macKeyCode: UInt16) -> KeyCode? {
        switch Int(macKeyCode) {
        case kVK_ANSI_A: return .a
        case kVK_ANSI_B: return .b
        case kVK_ANSI_C: return .c
        case kVK_ANSI_D: return .d
        case kVK_ANSI_E: return .e
        case kVK_ANSI_F: return .f
        case kVK_ANSI_G: return .g
        case kVK_ANSI_H: return .h
        case kVK_ANSI_I: return .i
        case kVK_ANSI_J: return .j
        case kVK_ANSI_K: return .k
        case kVK_ANSI_L: return .l
        case kVK_ANSI_M: return .m
        case kVK_ANSI_N: return .n
        case kVK_ANSI_O: return .o
        case kVK_ANSI_P: return .p
        case kVK_ANSI_Q: return .q
        case kVK_ANSI_R: return .r
        case kVK_ANSI_S: return .s
        case kVK_ANSI_T: return .t
        case kVK_ANSI_U: return .u
        case kVK_ANSI_V: return .v
        case kVK_ANSI_W: return .w
        case kVK_ANSI_X: return .x
        case kVK_ANSI_Y: return .y
        case kVK_ANSI_Z: return .z

        case kVK_ANSI_0: return .digit0
        case kVK_ANSI_1: return .digit1
        case kVK_ANSI_2: return .digit2
        case kVK_ANSI_3: return .digit3
        case kVK_ANSI_4: return .digit4
        case kVK_ANSI_5: return .digit5
        case kVK_ANSI_6: return .digit6
        case kVK_ANSI_7: return .digit7
        case kVK_ANSI_8: return .digit8
        case kVK_ANSI_9: return .digit9

        case kVK_Return, kVK_ANSI_KeypadEnter: return .enter
        case kVK_Tab: return .tab
        case kVK_Space: return .space
        case kVK_Delete: return .backspace
        case kVK_ForwardDelete: return .delete
        case kVK_Escape: return .escape
        case kVK_CapsLock: return .capsLock
        case kVK_Home: return .home
        case kVK_End: return .end
        case kVK_PageUp: return .pageUp
        case kVK_PageDown: return .pageDown
        case kVK_Help: return .help
        case kVK_LeftArrow: return .leftArrow
        case kVK_RightArrow: return .rightArrow
        case kVK_UpArrow: return .upArrow
        case kVK_DownArrow: return .downArrow

        case kVK_Command: return .leftCommand
        case kVK_RightCommand: return .rightCommand
        case kVK_Shift: return .leftShift
        case kVK_RightShift: return .rightShift
        case kVK_Control: return .leftControl
        case kVK_RightControl: return .rightControl
        case kVK_Option: return .leftAlt
        case kVK_RightOption: return .rightAlt

        case kVK_ANSI_Keypad0: return .keypad0
        case kVK_ANSI_Keypad1: return .keypad1
        case kVK_ANSI_Keypad2: return .keypad2
        case kVK_ANSI_Keypad3: return .keypad3
        case kVK_ANSI_Keypad4: return .keypad4
        case kVK_ANSI_Keypad5: return .keypad5
        case kVK_ANSI_Keypad6: return .keypad6
        case kVK_ANSI_Keypad7: return .keypad7
        case kVK_ANSI_Keypad8: return .keypad8
        case kVK_ANSI_Keypad9: return .keypad9
        case kVK_ANSI_KeypadDecimal: return .keypadDecimal
        case kVK_ANSI_KeypadMultiply: return .keypadMultiply
        case kVK_ANSI_KeypadPlus: return .keypadAdd
        case kVK_ANSI_KeypadMinus: return .keypadSubtract
        case kVK_ANSI_KeypadDivide: return .keypadDivide
        case kVK_ANSI_KeypadClear: return .clear

        case kVK_ANSI_Equal: return .equal
        case kVK_ANSI_Minus: return .minus
        case kVK_ANSI_LeftBracket: return .leftBracket
        case kVK_ANSI_RightBracket: return .rightBracket
        case kVK_ANSI_Backslash: return .backslash
        case kVK_ANSI_Semicolon: return .semicolon
        case kVK_ANSI_Quote: return .quote
        case kVK_ANSI_Comma: return .comma
        case kVK_ANSI_Period: return .period
        case kVK_ANSI_Slash: return .slash
        case kVK_ANSI_Grave: return .backtick

        case kVK_F1: return .f1
        case kVK_F2: return .f2
        case kVK_F3: return .f3
        case kVK_F4: return .f4
        case kVK_F5: return .f5
        case kVK_F6: return .f6
        case kVK_F7: return .f7
        case kVK_F8: return .f8
        case kVK_F9: return .f9
        case kVK_F10: return .f10
        case kVK_F11: return .f11
        case kVK_F12: return .f12
        case kVK_F13: return .f13
        case kVK_F14: return .f14
        case kVK_F15: return .f15
        case kVK_F16: return .f16
        case kVK_F17: return .f17
        case kVK_F18: return .f18
        case kVK_F19: return .f19
        case kVK_F20: return .f20

        default:
            return nil
        }
    }

    private static func containsRawModifierMask(_ rawMask: NSEvent.ModifierFlags.RawValue, in flags: NSEvent.ModifierFlags) -> Bool {
        flags.rawValue & rawMask != 0
    }
}
#endif
