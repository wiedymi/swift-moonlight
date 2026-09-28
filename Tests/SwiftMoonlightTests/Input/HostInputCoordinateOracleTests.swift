import CoreGraphics
import Foundation
import Testing
@testable import SwiftMoonlight

@Test
func hostInputCoordinateOracleMapsAbsoluteMouseEdgesThroughMoonlightPacketDimensions() throws {
    let packet = try absoluteMousePacket(x: 1, y: 1, width: 1_920, height: 1_080)
    let oracle = HostInputCoordinateOracle(
        hostKind: .apollo,
        touchPort: HostInputTouchPort(
            streamSize: CGSize(width: 1_920, height: 1_080),
            displaySize: CGSize(width: 1_920, height: 1_080),
            environmentSize: CGSize(width: 1_920, height: 1_080)
        )
    )

    let mapped = try #require(oracle.mapAbsoluteMousePacket(
        x: packet.x,
        y: packet.y,
        packetWidth: packet.width,
        packetHeight: packet.height
    ))

    #expect(packet.x == 1_920)
    #expect(packet.y == 1_080)
    #expect(packet.width == 1_919)
    #expect(packet.height == 1_079)
    expectClose(mapped.pointInPort.x, 1_920)
    expectClose(mapped.pointInPort.y, 1_080)
    #expect(mapped.portSize == CGSize(width: 1_920, height: 1_080))
}

@Test
func hostInputCoordinateOracleModelsApolloLetterboxClamp() throws {
    let topPacket = try absoluteMousePacket(x: 0.5, y: 0, width: 1_920, height: 1_200)
    let bottomPacket = try absoluteMousePacket(x: 0.5, y: 1, width: 1_920, height: 1_200)
    let oracle = HostInputCoordinateOracle(
        hostKind: .apollo,
        touchPort: HostInputTouchPort(
            streamSize: CGSize(width: 1_920, height: 1_200),
            displaySize: CGSize(width: 1_920, height: 1_080),
            environmentSize: CGSize(width: 1_920, height: 1_080)
        )
    )

    let top = try #require(oracle.mapAbsoluteMousePacket(
        x: topPacket.x,
        y: topPacket.y,
        packetWidth: topPacket.width,
        packetHeight: topPacket.height
    ))
    let bottom = try #require(oracle.mapAbsoluteMousePacket(
        x: bottomPacket.x,
        y: bottomPacket.y,
        packetWidth: bottomPacket.width,
        packetHeight: bottomPacket.height
    ))

    expectClose(top.pointInPort.y, 0)
    expectClose(bottom.pointInPort.y, 1_080)
}

@Test
func hostInputCoordinateOracleModelsSunshineLogicalTouchPortScaling() throws {
    let packet = try absoluteMousePacket(x: 0.5, y: 0.5, width: 3_840, height: 2_160)
    let physicalPort = HostInputTouchPort(
        streamSize: CGSize(width: 3_840, height: 2_160),
        displaySize: CGSize(width: 3_840, height: 2_160),
        environmentSize: CGSize(width: 3_840, height: 2_160),
        logicalDisplaySize: CGSize(width: 1_920, height: 1_080),
        logicalEnvironmentSize: CGSize(width: 1_920, height: 1_080)
    )
    let sunshine = HostInputCoordinateOracle(hostKind: .sunshine, touchPort: physicalPort)
    let apollo = HostInputCoordinateOracle(hostKind: .apollo, touchPort: physicalPort)

    let sunshineMapped = try #require(sunshine.mapAbsoluteMousePacket(
        x: packet.x,
        y: packet.y,
        packetWidth: packet.width,
        packetHeight: packet.height
    ))
    let apolloMapped = try #require(apollo.mapAbsoluteMousePacket(
        x: packet.x,
        y: packet.y,
        packetWidth: packet.width,
        packetHeight: packet.height
    ))

    #expect(sunshineMapped.portSize == CGSize(width: 1_920, height: 1_080))
    #expect(apolloMapped.portSize == CGSize(width: 3_840, height: 2_160))
    expectClose(sunshineMapped.pointInPort.x * 2, apolloMapped.pointInPort.x)
    expectClose(sunshineMapped.pointInPort.y * 2, apolloMapped.pointInPort.y)
}

@Test
func hostInputCoordinateOracleKeepsTouchNormalizedWhilePortsDiverge() throws {
    let physicalPort = HostInputTouchPort(
        streamSize: CGSize(width: 3_840, height: 2_160),
        displaySize: CGSize(width: 3_840, height: 2_160),
        environmentSize: CGSize(width: 3_840, height: 2_160),
        displayOffset: CGPoint(x: 120, y: 40),
        logicalDisplaySize: CGSize(width: 1_920, height: 1_080),
        logicalEnvironmentSize: CGSize(width: 1_920, height: 1_080)
    )
    let sunshine = try #require(
        HostInputCoordinateOracle(hostKind: .sunshine, touchPort: physicalPort)
            .mapNormalizedTouch(x: 0.75, y: 0.25)
    )
    let apollo = try #require(
        HostInputCoordinateOracle(hostKind: .apollo, touchPort: physicalPort)
            .mapNormalizedTouch(x: 0.75, y: 0.25)
    )

    #expect(sunshine.portOrigin == CGPoint(x: 120, y: 40))
    #expect(sunshine.portSize == CGSize(width: 1_920, height: 1_080))
    #expect(apollo.portSize == CGSize(width: 3_840, height: 2_160))
    expectClose(sunshine.normalizedPoint.x, apollo.normalizedPoint.x)
    expectClose(sunshine.normalizedPoint.y, apollo.normalizedPoint.y)
    expectClose(sunshine.normalizedPoint.x, 0.75)
    expectClose(sunshine.normalizedPoint.y, 0.25)
}

private struct AbsoluteMousePacket {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

private func absoluteMousePacket(
    x: Double,
    y: Double,
    width: Int16,
    height: Int16
) throws -> AbsoluteMousePacket {
    let encoder = BinaryInputEncoder()
    let context = InputEncodingContext(
        hostKind: .apollo,
        absoluteReferenceWidth: width,
        absoluteReferenceHeight: height
    )
    let packet = try #require(try encoder.encode(.mouse(.absoluteMove(x: x, y: y)), context: context).first)
    let payload = packet.payload
    #expect(payload.count == 18)
    return AbsoluteMousePacket(
        x: Double(readUInt16BE(payload, offset: 8)),
        y: Double(readUInt16BE(payload, offset: 10)),
        width: Double(readUInt16BE(payload, offset: 14)),
        height: Double(readUInt16BE(payload, offset: 16))
    )
}

private func readUInt16BE(_ data: Data, offset: Int) -> UInt16 {
    let b0 = UInt16(data[data.startIndex.advanced(by: offset)])
    let b1 = UInt16(data[data.startIndex.advanced(by: offset + 1)])
    return (b0 << 8) | b1
}

private func expectClose(
    _ actual: CGFloat,
    _ expected: CGFloat,
    tolerance: CGFloat = 0.001,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(abs(actual - expected) <= tolerance, sourceLocation: sourceLocation)
}
