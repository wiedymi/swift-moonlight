#if os(macOS)
import AppKit
import Carbon.HIToolbox
import SwiftMoonlight
import SwiftMoonlightTestAppSupport
import Testing

@Test
func testAppSurfaceInputStateSuppressesKeyboardRepeatsAndDuplicates() {
    var state = TestAppSurfaceInputState()

    expectKeyboard(
        state.keyDown(macKeyCode: UInt16(kVK_ANSI_A), isRepeat: false, modifierFlags: []),
        keyCode: .a,
        isDown: true
    )
    #expect(state.keyDown(macKeyCode: UInt16(kVK_ANSI_A), isRepeat: true, modifierFlags: []) == nil)
    #expect(state.keyDown(macKeyCode: UInt16(kVK_ANSI_A), isRepeat: false, modifierFlags: []) == nil)

    expectKeyboard(
        state.keyUp(macKeyCode: UInt16(kVK_ANSI_A), modifierFlags: []),
        keyCode: .a,
        isDown: false
    )
    #expect(state.keyUp(macKeyCode: UInt16(kVK_ANSI_A), modifierFlags: []) == nil)
}

@Test
func testAppSurfaceInputStateUsesSideSpecificModifierFlags() {
    var state = TestAppSurfaceInputState()

    let leftShiftFlags = modifierFlags(rawMask: 0x00000002, deviceIndependent: .shift)
    expectKeyboard(
        state.modifierChanged(macKeyCode: UInt16(kVK_Shift), modifierFlags: leftShiftFlags),
        keyCode: .leftShift,
        isDown: true
    )
    #expect(state.modifierChanged(macKeyCode: UInt16(kVK_Shift), modifierFlags: leftShiftFlags) == nil)

    let bothShiftFlags = modifierFlags(rawMask: 0x00000002 | 0x00000004, deviceIndependent: .shift)
    expectKeyboard(
        state.modifierChanged(macKeyCode: UInt16(kVK_RightShift), modifierFlags: bothShiftFlags),
        keyCode: .rightShift,
        isDown: true
    )

    let rightShiftOnlyFlags = modifierFlags(rawMask: 0x00000004, deviceIndependent: .shift)
    expectKeyboard(
        state.modifierChanged(macKeyCode: UInt16(kVK_Shift), modifierFlags: rightShiftOnlyFlags),
        keyCode: .leftShift,
        isDown: false
    )

    expectKeyboard(
        state.modifierChanged(macKeyCode: UInt16(kVK_RightShift), modifierFlags: []),
        keyCode: .rightShift,
        isDown: false
    )
}

@Test
func testAppSurfaceInputStateSuppressesDuplicateMouseButtons() {
    var state = TestAppSurfaceInputState()

    expectMouseButton(
        state.pressMouseButton(.left, buttonNumber: 0),
        button: .left,
        state: .pressed
    )
    #expect(state.pressMouseButton(.left, buttonNumber: 0) == nil)

    expectMouseButton(
        state.releaseMouseButton(.left, buttonNumber: 0),
        button: .left,
        state: .released
    )
    #expect(state.releaseMouseButton(.left, buttonNumber: 0) == nil)
}

@Test
func testAppSurfaceInputMapperKeepsAppKitTrackpadRelativeYDirection() {
    let delta = TestAppSurfaceInputMapper.relativePointerDelta(appKitDeltaX: 2.5, appKitDeltaY: 3.5)

    #expect(delta.x == 2.5)
    #expect(delta.y == 3.5)
}

@Test
func testAppSurfaceInputStateReleasesTrackedInputOnTeardown() {
    var state = TestAppSurfaceInputState()

    _ = state.pressMouseButton(.left, buttonNumber: 0)
    _ = state.keyDown(macKeyCode: UInt16(kVK_ANSI_B), isRepeat: false, modifierFlags: [])
    _ = state.modifierChanged(
        macKeyCode: UInt16(kVK_Command),
        modifierFlags: modifierFlags(rawMask: 0x00000008, deviceIndependent: .command)
    )

    let releaseEvents = state.releaseTrackedInput()
    #expect(releaseEvents.count == 3)
    expectMouseButton(releaseEvents[safe: 0], button: .left, state: .released)
    expectKeyboard(releaseEvents[safe: 1], keyCode: .b, isDown: false)
    expectKeyboard(releaseEvents[safe: 2], keyCode: .leftCommand, isDown: false)
    #expect(state.releaseTrackedInput().isEmpty)
}

private func modifierFlags(
    rawMask: NSEvent.ModifierFlags.RawValue,
    deviceIndependent: NSEvent.ModifierFlags
) -> NSEvent.ModifierFlags {
    NSEvent.ModifierFlags(rawValue: rawMask | deviceIndependent.rawValue)
}

private func expectKeyboard(_ event: InputEvent?, keyCode expectedKeyCode: KeyCode, isDown: Bool) {
    guard let event else {
        Issue.record("Expected keyboard event")
        return
    }

    switch event {
    case let .keyboard(.keyDown(keyCode, _)) where isDown:
        #expect(keyCode == expectedKeyCode)
    case let .keyboard(.keyUp(keyCode, _)) where !isDown:
        #expect(keyCode == expectedKeyCode)
    default:
        Issue.record("Unexpected event \(event)")
    }
}

private func expectMouseButton(_ event: InputEvent?, button expectedButton: MouseButton, state expectedState: ButtonState) {
    guard let event else {
        Issue.record("Expected mouse button event")
        return
    }

    switch event {
    case let .mouse(.button(button, state)):
        #expect(sameMouseButton(button, expectedButton))
        #expect(sameButtonState(state, expectedState))
    default:
        Issue.record("Unexpected event \(event)")
    }
}

private func sameMouseButton(_ lhs: MouseButton, _ rhs: MouseButton) -> Bool {
    switch (lhs, rhs) {
    case (.left, .left), (.middle, .middle), (.right, .right), (.x1, .x1), (.x2, .x2):
        return true
    default:
        return false
    }
}

private func sameButtonState(_ lhs: ButtonState, _ rhs: ButtonState) -> Bool {
    switch (lhs, rhs) {
    case (.pressed, .pressed), (.released, .released):
        return true
    default:
        return false
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
#endif
