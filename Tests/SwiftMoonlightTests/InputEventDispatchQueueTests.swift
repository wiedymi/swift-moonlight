import Testing
@testable import SwiftMoonlight

@Test
func inputEventDispatchQueuePreservesSequenceAcrossOutOfOrderIngress() async {
    let sender = RecordingInputEventSender()
    let queue = InputEventDispatchQueue()

    await queue.enqueue(.keyboard(.keyDown(.a)), sender: sender, sequence: 1, generation: 0)
    #expect(await sender.snapshot().isEmpty)

    await queue.enqueue(.keyboard(.keyDown(.space)), sender: sender, sequence: 0, generation: 0)
    await queue.waitUntilIdle()

    let events = await sender.snapshot()
    #expect(events.count == 2)
    #expect(keyDownCode(events[safe: 0]) == .space)
    #expect(keyDownCode(events[safe: 1]) == .a)
}

@Test
func inputEventDispatchQueueCoalescesMouseMotionBeforeButtons() async {
    let sender = RecordingInputEventSender()
    let queue = InputEventDispatchQueue()

    await queue.enqueue(.mouse(.absoluteMove(x: 0.1, y: 0.2)), sender: sender, sequence: 1, generation: 0)
    await queue.enqueue(.mouse(.button(button: .left, state: .pressed)), sender: sender, sequence: 2, generation: 0)
    await queue.enqueue(.mouse(.absoluteMove(x: 0.5, y: 0.25)), sender: sender, sequence: 0, generation: 0)
    await queue.waitUntilIdle()

    let events = await sender.snapshot()
    #expect(events.count == 2)
    #expect(isAbsoluteMousePosition(events[safe: 0], x: 0.1, y: 0.2))
    #expect(isLeftMousePress(events[safe: 1]))
}

@Test
func inputEventDispatchQueueClearsStaleGeneration() async {
    let sender = RecordingInputEventSender()
    let queue = InputEventDispatchQueue()

    await queue.enqueue(.keyboard(.keyDown(.a)), sender: sender, sequence: 1, generation: 0)
    await queue.clear(generation: 1)
    await queue.enqueue(.keyboard(.keyDown(.space)), sender: sender, sequence: 0, generation: 0)
    await queue.enqueue(.keyboard(.keyDown(.enter)), sender: sender, sequence: 0, generation: 1)
    await queue.waitUntilIdle()

    let events = await sender.snapshot()
    #expect(events.count == 1)
    #expect(keyDownCode(events[safe: 0]) == .enter)
}

@Test
func inputEventDispatchQueueReportsSendFailures() async {
    let sender = FailingInputEventSender()
    let failures = RecordingInputDispatchFailures()
    let queue = InputEventDispatchQueue { failure in
        await failures.record(failure)
    }

    await queue.enqueue(.keyboard(.keyDown(.space)), sender: sender, sequence: 0, generation: 0)
    await queue.waitUntilIdle()

    let recordedFailures = await failures.snapshot()
    #expect(recordedFailures == [InputDispatchFailure(message: "synthetic failure")])
}

private actor RecordingInputEventSender: InputSending {
    private var events: [InputEvent] = []

    func send(_ event: InputEvent) async throws {
        events.append(event)
    }

    func snapshot() -> [InputEvent] {
        events
    }
}

private actor FailingInputEventSender: InputSending {
    func send(_ event: InputEvent) async throws {
        _ = event
        throw MoonlightError(.unsupportedOperation, message: "synthetic failure")
    }
}

private actor RecordingInputDispatchFailures {
    private var failures: [InputDispatchFailure] = []

    func record(_ failure: InputDispatchFailure) {
        failures.append(failure)
    }

    func snapshot() -> [InputDispatchFailure] {
        failures
    }
}

private func keyDownCode(_ event: InputEvent?) -> KeyCode? {
    guard case .keyboard(.keyDown(let keyCode, _)) = event else {
        return nil
    }
    return keyCode
}

private func isAbsoluteMousePosition(_ event: InputEvent?, x expectedX: Double, y expectedY: Double) -> Bool {
    guard case .mouse(.absoluteMove(let x, let y)) = event else {
        return false
    }
    return x == expectedX && y == expectedY
}

private func isLeftMousePress(_ event: InputEvent?) -> Bool {
    guard case .mouse(.button(.left, .pressed)) = event else {
        return false
    }
    return true
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        guard indices.contains(index) else {
            return nil
        }
        return self[index]
    }
}
