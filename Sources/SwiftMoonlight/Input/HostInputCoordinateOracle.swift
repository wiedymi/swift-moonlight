import CoreGraphics
import Foundation

public struct HostInputTouchPort: Sendable, Equatable {
    public var streamSize: CGSize
    public var displaySize: CGSize
    public var environmentSize: CGSize
    public var displayOffset: CGPoint
    public var logicalDisplaySize: CGSize?
    public var logicalEnvironmentSize: CGSize?

    public init(
        streamSize: CGSize,
        displaySize: CGSize,
        environmentSize: CGSize,
        displayOffset: CGPoint = .zero,
        logicalDisplaySize: CGSize? = nil,
        logicalEnvironmentSize: CGSize? = nil
    ) {
        self.streamSize = streamSize
        self.displaySize = displaySize
        self.environmentSize = environmentSize
        self.displayOffset = displayOffset
        self.logicalDisplaySize = logicalDisplaySize
        self.logicalEnvironmentSize = logicalEnvironmentSize
    }
}

public struct HostAbsoluteMouseMapping: Sendable, Equatable {
    public var pointInPort: CGPoint
    public var portOrigin: CGPoint
    public var portSize: CGSize

    public init(pointInPort: CGPoint, portOrigin: CGPoint, portSize: CGSize) {
        self.pointInPort = pointInPort
        self.portOrigin = portOrigin
        self.portSize = portSize
    }
}

public struct HostNormalizedTouchMapping: Sendable, Equatable {
    public var normalizedPoint: CGPoint
    public var portOrigin: CGPoint
    public var portSize: CGSize

    public init(normalizedPoint: CGPoint, portOrigin: CGPoint, portSize: CGSize) {
        self.normalizedPoint = normalizedPoint
        self.portOrigin = portOrigin
        self.portSize = portSize
    }
}

public struct HostInputCoordinateOracle: Sendable, Equatable {
    public var hostKind: HostKind
    public var touchPort: HostInputTouchPort

    public init(hostKind: HostKind, touchPort: HostInputTouchPort) {
        self.hostKind = hostKind
        self.touchPort = touchPort
    }

    public func mapAbsoluteMousePacket(
        x: Double,
        y: Double,
        packetWidth: Double,
        packetHeight: Double
    ) -> HostAbsoluteMouseMapping? {
        guard let point = mapClientPoint(
            CGPoint(x: CGFloat(x), y: CGFloat(y)),
            clientSize: CGSize(width: CGFloat(packetWidth), height: CGFloat(packetHeight))
        ) else {
            return nil
        }

        return HostAbsoluteMouseMapping(
            pointInPort: point,
            portOrigin: touchPort.displayOffset,
            portSize: absoluteMousePortSize
        )
    }

    public func mapNormalizedTouch(x: Double, y: Double) -> HostNormalizedTouchMapping? {
        guard let point = mapClientPoint(
            CGPoint(
                x: CGFloat(clamp(x, lower: 0, upper: 1) * 65_535),
                y: CGFloat(clamp(y, lower: 0, upper: 1) * 65_535)
            ),
            clientSize: CGSize(width: 65_535, height: 65_535)
        ) else {
            return nil
        }

        let portOrigin = touchPort.displayOffset
        let portSize = normalizedTouchPortSize
        guard portSize.width > 0, portSize.height > 0 else {
            return nil
        }

        let normalizedPoint: CGPoint
        if hostKind == .sunshine {
            normalizedPoint = CGPoint(
                x: (point.x - portOrigin.x) / portSize.width,
                y: (point.y - portOrigin.y) / portSize.height
            )
        } else {
            normalizedPoint = CGPoint(
                x: point.x / portSize.width,
                y: point.y / portSize.height
            )
        }

        return HostNormalizedTouchMapping(
            normalizedPoint: CGPoint(
                x: clamp(normalizedPoint.x, lower: 0, upper: 1),
                y: clamp(normalizedPoint.y, lower: 0, upper: 1)
            ),
            portOrigin: portOrigin,
            portSize: portSize
        )
    }

    private var absoluteMousePortSize: CGSize {
        if hostKind == .sunshine,
           let logicalEnvironmentSize = touchPort.logicalEnvironmentSize,
           logicalEnvironmentSize.width > 0,
           logicalEnvironmentSize.height > 0
        {
            return logicalEnvironmentSize
        }

        return touchPort.environmentSize
    }

    private var normalizedTouchPortSize: CGSize {
        if hostKind == .sunshine,
           let derived = derivedScalars
        {
            return CGSize(
                width: touchPort.streamSize.width * derived.scalarInverse / derived.touchCoordinateScale,
                height: touchPort.streamSize.height * derived.scalarInverse / derived.touchCoordinateScale
            )
        }

        return touchPort.environmentSize
    }

    private func mapClientPoint(_ point: CGPoint, clientSize: CGSize) -> CGPoint? {
        guard let derived = derivedScalars,
              clientSize.width > 0,
              clientSize.height > 0
        else {
            return nil
        }

        let scalarX = touchPort.streamSize.width / clientSize.width
        let scalarY = touchPort.streamSize.height / clientSize.height

        var x = clamp(point.x, lower: 0, upper: clientSize.width) * scalarX
        var y = clamp(point.y, lower: 0, upper: clientSize.height) * scalarY

        x = clamp(
            x,
            lower: derived.clientOffset.x,
            upper: clientSize.width * scalarX - derived.clientOffset.x
        )
        y = clamp(
            y,
            lower: derived.clientOffset.y,
            upper: clientSize.height * scalarY - derived.clientOffset.y
        )

        let commonX = (x - derived.clientOffset.x) * derived.scalarInverse
        let commonY = (y - derived.clientOffset.y) * derived.scalarInverse

        if hostKind == .sunshine {
            return CGPoint(
                x: (commonX + touchPort.displayOffset.x * derived.touchCoordinateScale) / derived.touchCoordinateScale,
                y: (commonY + touchPort.displayOffset.y * derived.touchCoordinateScale) / derived.touchCoordinateScale
            )
        }

        return CGPoint(x: commonX, y: commonY)
    }

    private var derivedScalars: (
        clientOffset: CGPoint,
        scalarInverse: CGFloat,
        touchCoordinateScale: CGFloat
    )? {
        guard touchPort.streamSize.width > 0,
              touchPort.streamSize.height > 0,
              touchPort.displaySize.width > 0,
              touchPort.displaySize.height > 0,
              touchPort.environmentSize.width > 0,
              touchPort.environmentSize.height > 0
        else {
            return nil
        }

        let streamToDisplayScale = min(
            touchPort.streamSize.width / touchPort.displaySize.width,
            touchPort.streamSize.height / touchPort.displaySize.height
        )
        guard streamToDisplayScale > 0 else {
            return nil
        }

        let scaledDisplaySize = CGSize(
            width: touchPort.displaySize.width * streamToDisplayScale,
            height: touchPort.displaySize.height * streamToDisplayScale
        )
        let clientOffset = CGPoint(
            x: (touchPort.streamSize.width - scaledDisplaySize.width) * 0.5,
            y: (touchPort.streamSize.height - scaledDisplaySize.height) * 0.5
        )

        let touchCoordinateScale: CGFloat
        if hostKind == .sunshine,
           let logicalDisplaySize = touchPort.logicalDisplaySize,
           let logicalEnvironmentSize = touchPort.logicalEnvironmentSize,
           logicalDisplaySize.width > 0,
           logicalDisplaySize.height > 0,
           logicalEnvironmentSize.width > 0,
           logicalEnvironmentSize.height > 0
        {
            touchCoordinateScale = min(
                touchPort.displaySize.width / logicalDisplaySize.width,
                touchPort.displaySize.height / logicalDisplaySize.height
            )
        } else {
            touchCoordinateScale = 1
        }

        guard touchCoordinateScale > 0 else {
            return nil
        }

        return (clientOffset, 1 / streamToDisplayScale, touchCoordinateScale)
    }
}

private func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
    min(max(value, lower), upper)
}

private func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
    min(max(value, lower), upper)
}
