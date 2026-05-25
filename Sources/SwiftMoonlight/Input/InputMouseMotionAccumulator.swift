import Foundation

public struct InputMouseMotionAccumulator: Sendable, Equatable {
    private var remainderDX = 0.0
    private var remainderDY = 0.0

    public init() {}

    public mutating func consume(deltaX: Double, deltaY: Double) -> [MouseEvent] {
        guard deltaX.isFinite, deltaY.isFinite else {
            return []
        }

        remainderDX += deltaX
        remainderDY += deltaY

        let wholeDX = Self.wholeDelta(from: remainderDX)
        let wholeDY = Self.wholeDelta(from: remainderDY)
        guard wholeDX != 0 || wholeDY != 0 else {
            return []
        }

        remainderDX -= Double(wholeDX)
        remainderDY -= Double(wholeDY)

        return InputMouseMotionBatch.relative(dx: wholeDX, dy: wholeDY).mouseEvents
    }

    public mutating func reset() {
        remainderDX = 0
        remainderDY = 0
    }

    private static func wholeDelta(from value: Double) -> Int {
        if value >= Double(Int.max) {
            return Int.max
        }
        if value <= Double(Int.min) {
            return Int.min
        }
        return Int(value.rounded(.towardZero))
    }
}
