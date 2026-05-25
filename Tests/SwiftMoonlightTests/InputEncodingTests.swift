import CoreGraphics
import Foundation
import Testing
@testable import SwiftMoonlight

@Test
func encodesRelativeMouseMovePacket() throws {
    let encoder = BinaryInputEncoder()
    let context = InputEncodingContext(hostKind: .sunshine)

    let packets = try encoder.encode(.mouse(.relativeMove(dx: 8, dy: -2)), context: context)

    #expect(packets.count == 1)
    #expect(packets[0].hexString == "00000008070000000008FFFE")
}

@Test
func encodesMouseButtonPacket() throws {
    let encoder = BinaryInputEncoder()
    let context = InputEncodingContext(hostKind: .sunshine)

    let packets = try encoder.encode(.mouse(.button(button: .left, state: .pressed)), context: context)

    #expect(packets.count == 1)
    #expect(packets[0].hexString == "000000050800000001")
}

@Test
func encodesAbsoluteMouseMovePacket() throws {
    let encoder = BinaryInputEncoder()
    let context = InputEncodingContext(hostKind: .sunshine)

    let packets = try encoder.encode(.mouse(.absoluteMove(x: 0.5, y: 0.25)), context: context)

    #expect(packets.count == 1)
    #expect(packets[0].hexString == "0000000C050000003FFF1FFF00007FFE7FFE")
}

@Test
func encodesAbsoluteMouseMovePacketWithConfiguredReferencePlane() throws {
    let encoder = BinaryInputEncoder()
    let context = InputEncodingContext(
        hostKind: .sunshine,
        absoluteReferenceWidth: 640,
        absoluteReferenceHeight: 360
    )

    let packets = try encoder.encode(.mouse(.absoluteMove(x: 0.5, y: 0.25)), context: context)

    #expect(packets.count == 1)
    #expect(packets[0].hexString == "0000000C050000000140005A0000027F0167")
}

@Test
func inputEncodingContextDerivesHostProfileAndReferencePlaneFromNegotiatedSession() throws {
    let encoder = BinaryInputEncoder()
    let host = MoonlightHost(
        id: HostID(),
        name: "Apollo Host",
        endpoint: .init(address: "apollo.local", port: 47989),
        kind: .apollo,
        pairingState: .paired,
        capabilities: .inferred(for: .apollo, codecSupportFlags: 0x0002_0200)
    )
    let negotiated = NegotiatedSession(
        hostID: host.id,
        appID: "desktop",
        rtspSessionURL: "rtsp://apollo.local:47998",
        videoFormat: .init(codec: .hevc, dimensions: CGSize(width: 2560, height: 1440))
    )

    let context = InputEncodingContext(host: host, negotiatedSession: negotiated)
    let packets = try encoder.encode(.mouse(.absoluteMove(x: 0.5, y: 0.25)), context: context)

    #expect(context.hostKind == .apollo)
    #expect(context.hostProfile.quirks.contains(.apolloTouchCoordinateTransform))
    #expect(context.streamViewport == CGSize(width: 2560, height: 1440))
    #expect(context.absoluteReferenceWidth == 2560)
    #expect(context.absoluteReferenceHeight == 1440)
    #expect(packets.count == 1)
    #expect(packets[0].hexString == "0000000C0500000005000168000009FF059F")
}

@Test
func encodesVerticalScrollPacket() throws {
    let encoder = BinaryInputEncoder()
    let context = InputEncodingContext(hostKind: .sunshine)

    let packets = try encoder.encode(.mouse(.verticalScroll(delta: 120)), context: context)

    #expect(packets.count == 1)
    #expect(packets[0].hexString == "0000000A0A000000007800780000")
}

@Test
func encodesHorizontalScrollPacket() throws {
    let encoder = BinaryInputEncoder()
    let context = InputEncodingContext(hostKind: .sunshine)

    let packets = try encoder.encode(.mouse(.horizontalScroll(delta: -120)), context: context)

    #expect(packets.count == 1)
    #expect(packets[0].hexString == "0000000601000055FF88")
}

@Test
func encodesKeyboardKeyDownPacket() throws {
    let encoder = BinaryInputEncoder()
    let context = InputEncodingContext(hostKind: .sunshine)

    let packets = try encoder.encode(.keyboard(.keyDown(.space)), context: context)

    #expect(packets.count == 1)
    #expect(packets[0].hexString == "0000000A03000000002000000000")
}

@Test
func encodesKeyboardArrowKeyDownPacket() throws {
    let encoder = BinaryInputEncoder()
    let context = InputEncodingContext(hostKind: .sunshine)

    let packets = try encoder.encode(.keyboard(.keyDown(.leftArrow)), context: context)

    #expect(packets.count == 1)
    #expect(packets[0].hexString == "0000000A03000000002500000000")
}

@Test
func encodesExtendedKeyboardModifierPacket() throws {
    let encoder = BinaryInputEncoder()
    let context = InputEncodingContext(hostKind: .sunshine)

    let packets = try encoder.encode(.keyboard(.keyDown(.rightShift, modifiers: [.shift])), context: context)

    #expect(packets.count == 1)
    #expect(packets[0].hexString == "0000000A0300000000A100010000")
}

@Test
func encodesKeyboardTextPacket() throws {
    let encoder = BinaryInputEncoder()
    let context = InputEncodingContext(hostKind: .sunshine)

    let packets = try encoder.encode(.keyboard(.text("A")), context: context)

    #expect(packets.count == 1)
    #expect(packets[0].hexString == "000000051700000041")
}

@Test
func encodesControllerArrivalPacket() throws {
    let encoder = BinaryInputEncoder()
    let context = InputEncodingContext(hostKind: .sunshine)
    let descriptor = ControllerDescriptor(
        id: ControllerID(rawValue: 1),
        kind: .xbox,
        supportedButtons: [.a, .b, .x, .y, .guide],
        supportsRumble: true,
        supportsTriggerRumble: false,
        supportsMotion: false,
        supportsTouchpad: false
    )

    let packets = try encoder.encode(.controller(.connected(descriptor)), context: context)

    #expect(packets.count == 2)
    #expect(packets[0].hexString == "0000000C040000550101030000F40000")
    #expect(packets[1].hexString == "0000001E0C0000001A000100020014000000000000000000000000009C0000005500")
}

@Test
func encodesControllerStatePacket() throws {
    let encoder = BinaryInputEncoder()
    let context = InputEncodingContext(hostKind: .sunshine)
    let state = ControllerState(
        id: ControllerID(rawValue: 1),
        buttons: [.a, .x, .guide, .leftShoulder],
        leftStick: SIMD2<Float>(0.5, -0.5),
        rightStick: SIMD2<Float>(0, 1),
        leftTrigger: 0.25,
        rightTrigger: 1.0
    )

    let packets = try encoder.encode(.controller(.stateChanged(state)), context: context)

    #expect(packets.count == 1)
    #expect(packets[0].hexString == "0000001E0C0000001A0001000200140000553FFFFF3F01C00000FF7F9C0000005500")
}

@Test
func encodesTouchPacket() throws {
    let encoder = BinaryInputEncoder()
    let context = InputEncodingContext(hostKind: .sunshine)
    let touch = TouchEvent(contacts: [
        .init(id: 7, phase: .began, x: 0.5, y: 0.25)
    ])

    let packets = try encoder.encode(.touch(touch), context: context)

    #expect(packets.count == 1)
    #expect(packets[0].hexString == "00000020020000550100FFFF070000000000003F0000803E000000000000000000000000")
}

@Test
func touchPacketsStayNormalizedAcrossSunshineAndApolloProfiles() throws {
    let encoder = BinaryInputEncoder()
    let event = TouchEvent(contacts: [
        .init(
            id: 11,
            phase: .moved,
            x: 0.33,
            y: 0.66,
            pressure: 0.75,
            rotation: 45,
            contactAreaMajor: 0.2,
            contactAreaMinor: 0.1
        )
    ])

    let sunshinePackets = try encoder.encode(.touch(event), context: InputEncodingContext(hostKind: .sunshine))
    let apolloPackets = try encoder.encode(.touch(event), context: InputEncodingContext(hostKind: .apollo))

    #expect(sunshinePackets == apolloPackets)
}

@Test
func clampsTouchPacketNormalizedFields() throws {
    let encoder = BinaryInputEncoder()
    let context = InputEncodingContext(hostKind: .apollo)
    let touch = TouchEvent(contacts: [
        .init(
            id: 12,
            phase: .began,
            x: -1,
            y: 2,
            pressure: 2,
            contactAreaMajor: -0.5,
            contactAreaMinor: 1.5
        )
    ])

    let packets = try encoder.encode(.touch(touch), context: context)
    let payload = try #require(packets.first?.payload)

    #expect(littleEndianFloat(in: payload, at: 16) == 0)
    #expect(littleEndianFloat(in: payload, at: 20) == 1)
    #expect(littleEndianFloat(in: payload, at: 24) == 1)
    #expect(littleEndianFloat(in: payload, at: 28) == 0)
    #expect(littleEndianFloat(in: payload, at: 32) == 1)
}

@Test
func encodesPenPacket() throws {
    let encoder = BinaryInputEncoder()
    let context = InputEncodingContext(hostKind: .sunshine)
    let pen = PenEvent(contact: .init(
        phase: .moved,
        toolType: .pen,
        buttons: [.primary],
        x: 0.25,
        y: 0.75,
        pressure: 0.5,
        rotation: 90,
        tilt: 12,
        contactAreaMajor: 0.2,
        contactAreaMinor: 0.1
    ))

    let packets = try encoder.encode(.pen(pen), context: context)

    #expect(packets.count == 1)
    #expect(packets[0].hexString == "0000002003000055030101000000803E0000403F0000003F5A000C00CDCC4C3ECDCCCC3D")
}

@Test
func penPacketsStayNormalizedAcrossSunshineAndApolloProfiles() throws {
    let encoder = BinaryInputEncoder()
    let event = PenEvent(contact: .init(
        phase: .moved,
        toolType: .pen,
        buttons: [],
        x: 0.125,
        y: 0.875,
        pressure: 0.5,
        rotation: 90,
        tilt: 12,
        contactAreaMajor: 0.4,
        contactAreaMinor: 0.2
    ))

    let sunshinePackets = try encoder.encode(.pen(event), context: InputEncodingContext(hostKind: .sunshine))
    let apolloPackets = try encoder.encode(.pen(event), context: InputEncodingContext(hostKind: .apollo))

    #expect(sunshinePackets == apolloPackets)
}

@Test
func clampsPenPacketNormalizedFields() throws {
    let encoder = BinaryInputEncoder()
    let context = InputEncodingContext(hostKind: .apollo)
    let pen = PenEvent(contact: .init(
        phase: .moved,
        toolType: .pen,
        x: -0.25,
        y: 1.25,
        pressure: -1,
        contactAreaMajor: 2,
        contactAreaMinor: -2
    ))

    let packets = try encoder.encode(.pen(pen), context: context)
    let payload = try #require(packets.first?.payload)

    #expect(littleEndianFloat(in: payload, at: 12) == 0)
    #expect(littleEndianFloat(in: payload, at: 16) == 1)
    #expect(littleEndianFloat(in: payload, at: 20) == 0)
    #expect(littleEndianFloat(in: payload, at: 28) == 1)
    #expect(littleEndianFloat(in: payload, at: 32) == 0)
}

@Test
func encodesControllerBatteryPacket() throws {
    let encoder = BinaryInputEncoder()
    let context = InputEncodingContext(hostKind: .sunshine)

    let packets = try encoder.encode(
        .controller(.battery(.init(id: .init(rawValue: 1), state: .charging, percentage: 77))),
        context: context
    )

    #expect(packets.count == 1)
    #expect(packets[0].hexString == "000000080700005501034D00")
}

@Test
func encodesControllerMotionPacket() throws {
    let encoder = BinaryInputEncoder()
    let context = InputEncodingContext(hostKind: .sunshine)

    let packets = try encoder.encode(
        .controller(.motion(.init(id: .init(rawValue: 1), motionType: .gyroscope, x: 1.5, y: -2.0, z: 0.25))),
        context: context
    )

    #expect(packets.count == 1)
    #expect(packets[0].hexString == "0000001406000055010200000000C03F000000C00000803E")
}

@Test
func encodesControllerTouchpadPacket() throws {
    let encoder = BinaryInputEncoder()
    let context = InputEncodingContext(hostKind: .sunshine)

    let packets = try encoder.encode(
        .controller(.touchpad(.init(id: .init(rawValue: 2), phase: .began, pointerID: 9, x: 0.5, y: 0.125, pressure: 0.75))),
        context: context
    )

    #expect(packets.count == 1)
    #expect(packets[0].hexString == "000000180500005502010000090000000000003F0000003E0000403F")
}

private func littleEndianFloat(in data: Data, at offset: Int) -> Float {
    var bitPattern: UInt32 = 0
    for byteOffset in 0..<4 {
        bitPattern |= UInt32(data[data.startIndex + offset + byteOffset]) << UInt32(byteOffset * 8)
    }
    return Float(bitPattern: bitPattern)
}
