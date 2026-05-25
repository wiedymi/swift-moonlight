import Foundation

package enum InputMouseMotionBatch: Sendable, Equatable {
    case relative(dx: Int, dy: Int)
    case absolute(x: Double, y: Double)

    package init?(_ event: MouseEvent) {
        switch event {
        case let .relativeMove(dx, dy):
            self = .relative(dx: Int(dx), dy: Int(dy))
        case let .absoluteMove(x, y):
            self = .absolute(x: x, y: y)
        default:
            return nil
        }
    }

    package func merged(with next: InputMouseMotionBatch) -> InputMouseMotionBatch {
        switch (self, next) {
        case let (.relative(dx, dy), .relative(nextDX, nextDY)):
            return .relative(
                dx: Self.clampedAdd(dx, nextDX),
                dy: Self.clampedAdd(dy, nextDY)
            )
        case (_, .absolute(let x, let y)):
            return .absolute(x: x, y: y)
        case (_, .relative(let dx, let dy)):
            return .relative(dx: dx, dy: dy)
        }
    }

    package var mouseEvents: [MouseEvent] {
        switch self {
        case let .relative(dx, dy):
            return Self.splitRelativeMotion(dx: dx, dy: dy)
        case let .absolute(x, y):
            return [.absoluteMove(x: x, y: y)]
        }
    }

    package var inputEvents: [InputEvent] {
        mouseEvents.map(InputEvent.mouse)
    }

    private static func splitRelativeMotion(dx: Int, dy: Int) -> [MouseEvent] {
        var remainingDX = dx
        var remainingDY = dy
        var events: [MouseEvent] = []

        repeat {
            let packetDX = Int16(clamping: remainingDX)
            let packetDY = Int16(clamping: remainingDY)
            events.append(.relativeMove(dx: packetDX, dy: packetDY))
            remainingDX -= Int(packetDX)
            remainingDY -= Int(packetDY)
        } while remainingDX != 0 || remainingDY != 0

        return events
    }

    private static func clampedAdd(_ lhs: Int, _ rhs: Int) -> Int {
        if rhs > 0, lhs > Int.max - rhs {
            return Int.max
        }
        if rhs < 0, lhs < Int.min - rhs {
            return Int.min
        }
        return lhs + rhs
    }
}
