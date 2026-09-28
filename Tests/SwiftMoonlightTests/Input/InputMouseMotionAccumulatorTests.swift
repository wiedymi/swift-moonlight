import Foundation
import Testing
@testable import SwiftMoonlight

@Test
func inputMouseMotionAccumulatorPreservesFractionalMovement() throws {
    var accumulator = InputMouseMotionAccumulator()

    #expect(accumulator.consume(deltaX: 0.4, deltaY: -0.4).isEmpty)
    #expect(accumulator.consume(deltaX: 0.4, deltaY: -0.4).isEmpty)

    let events = accumulator.consume(deltaX: 0.4, deltaY: -0.4)
    #expect(events.count == 1)

    let motion = try #require(relativeMove(events[0]))
    #expect(motion.dx == 1)
    #expect(motion.dy == -1)
}

@Test
func inputMouseMotionAccumulatorKeepsRemainderAfterDispatch() throws {
    var accumulator = InputMouseMotionAccumulator()

    let firstEvents = accumulator.consume(deltaX: 1.75, deltaY: 0)
    let firstEvent = try #require(firstEvents.first)
    let firstMotion = try #require(relativeMove(firstEvent))
    #expect(firstMotion.dx == 1)
    #expect(firstMotion.dy == 0)

    let secondEvents = accumulator.consume(deltaX: 0.30, deltaY: 0)
    let secondEvent = try #require(secondEvents.first)
    let secondMotion = try #require(relativeMove(secondEvent))
    #expect(secondMotion.dx == 1)
    #expect(secondMotion.dy == 0)
}

@Test
func inputMouseMotionAccumulatorResetsStoredRemainder() {
    var accumulator = InputMouseMotionAccumulator()

    #expect(accumulator.consume(deltaX: 0.75, deltaY: 0).isEmpty)
    accumulator.reset()
    #expect(accumulator.consume(deltaX: 0.30, deltaY: 0).isEmpty)
}

@Test
func inputMouseMotionAccumulatorSplitsOversizedWholeMovement() throws {
    var accumulator = InputMouseMotionAccumulator()

    let events = accumulator.consume(
        deltaX: Double(Int(Int16.max) + 2),
        deltaY: Double(Int(Int16.min) - 3)
    )
    #expect(events.count == 2)

    let firstMotion = try #require(relativeMove(events[0]))
    #expect(firstMotion.dx == Int16.max)
    #expect(firstMotion.dy == Int16.min)

    let secondMotion = try #require(relativeMove(events[1]))
    #expect(secondMotion.dx == 2)
    #expect(secondMotion.dy == -3)
}

private func relativeMove(_ event: MouseEvent) -> (dx: Int16, dy: Int16)? {
    guard case let .relativeMove(dx, dy) = event else {
        return nil
    }
    return (dx, dy)
}
