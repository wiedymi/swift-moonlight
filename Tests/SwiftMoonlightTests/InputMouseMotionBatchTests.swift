import Foundation
import Testing
@testable import SwiftMoonlight

@Test
func inputMouseMotionBatchSplitsOversizedRelativeMotionInsteadOfClamping() throws {
    let batch = InputMouseMotionBatch.relative(
        dx: Int(Int16.max) + 5,
        dy: Int(Int16.min) - 5
    )

    let events = batch.mouseEvents
    #expect(events.count == 2)

    let first = try #require(relativeMove(events[0]))
    #expect(first.dx == Int16.max)
    #expect(first.dy == Int16.min)

    let second = try #require(relativeMove(events[1]))
    #expect(second.dx == 5)
    #expect(second.dy == -5)
}

@Test
func inputMouseMotionBatchAccumulatesRelativeMotionLosslessly() throws {
    let batch = InputMouseMotionBatch
        .relative(dx: Int(Int16.max), dy: 8)
        .merged(with: .relative(dx: 4, dy: -3))

    let events = batch.mouseEvents
    #expect(events.count == 2)

    let first = try #require(relativeMove(events[0]))
    #expect(first.dx == Int16.max)
    #expect(first.dy == 5)

    let second = try #require(relativeMove(events[1]))
    #expect(second.dx == 4)
    #expect(second.dy == 0)
}

@Test
func inputMouseMotionBatchKeepsLatestAbsolutePosition() throws {
    let batch = InputMouseMotionBatch
        .relative(dx: 16, dy: 9)
        .merged(with: .absolute(x: 0.25, y: 0.75))
        .merged(with: .absolute(x: 0.5, y: 0.125))

    let events = batch.inputEvents
    #expect(events.count == 1)

    guard case let .mouse(.absoluteMove(x, y)) = events[0] else {
        Issue.record("Expected absolute mouse move")
        return
    }
    #expect(x == 0.5)
    #expect(y == 0.125)
}

@Test
func inputMouseMotionBatchRelativeMotionReplacesPendingAbsoluteMotion() throws {
    let batch = InputMouseMotionBatch
        .absolute(x: 0.25, y: 0.75)
        .merged(with: .relative(dx: -7, dy: 11))

    let event = try #require(batch.mouseEvents.first)
    let motion = try #require(relativeMove(event))
    #expect(motion.dx == -7)
    #expect(motion.dy == 11)
}

private func relativeMove(_ event: MouseEvent) -> (dx: Int16, dy: Int16)? {
    guard case let .relativeMove(dx, dy) = event else {
        return nil
    }
    return (dx, dy)
}
