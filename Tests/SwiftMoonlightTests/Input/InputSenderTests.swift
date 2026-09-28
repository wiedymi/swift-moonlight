import Foundation
import Testing
@testable import SwiftMoonlight

@Test
func inputSenderEncodesAndTransportsPackets() async throws {
    let transport = RecordingInputTransport()
    let sender = InputSender(
        context: InputEncodingContext(hostKind: .sunshine),
        transport: transport
    )

    try await sender.send(.keyboard(.keyDown(.space)))

    let packets = await transport.recordedPackets()
    #expect(packets.count == 1)
    #expect(packets[0].packet.hexString == "0000000A03000000002000000000")
    #expect(packets[0].channelID == ControlChannelID.keyboard)
    #expect(packets[0].reliable)
}

@Test
func inputSenderCoalescesQueuedAbsoluteMouseMoves() async throws {
    let transport = RecordingInputTransport()
    let sender = InputSender(
        context: InputEncodingContext(
            hostKind: .sunshine,
            absoluteReferenceWidth: 640,
            absoluteReferenceHeight: 360
        ),
        transport: transport
    )

    try await sender.send(.mouse(.absoluteMove(x: 0.1, y: 0.2)))
    try await sender.send(.mouse(.absoluteMove(x: 0.5, y: 0.25)))
    try await sender.flushPendingMouseMotion()

    let packets = await transport.recordedPackets()
    #expect(packets.count == 1)
    #expect(packets[0].packet.hexString == "0000000C050000000140005A0000027F0167")
    #expect(packets[0].channelID == ControlChannelID.mouse)
    #expect(packets[0].reliable)
}

@Test
func inputSenderImmediateMouseMotionSendsWithoutExplicitFlush() async throws {
    let transport = RecordingInputTransport()
    let sender = InputSender(
        context: InputEncodingContext(
            hostKind: .sunshine,
            absoluteReferenceWidth: 640,
            absoluteReferenceHeight: 360
        ),
        transport: transport,
        configuration: .init(mouseMotionDeliveryPolicy: .immediate)
    )

    try await sender.send(.mouse(.absoluteMove(x: 0.5, y: 0.25)))

    let packets = await transport.recordedPackets()
    #expect(packets.count == 1)
    #expect(packets[0].packet.hexString == "0000000C050000000140005A0000027F0167")
    #expect(packets[0].channelID == ControlChannelID.mouse)
    #expect(packets[0].reliable)
}

@Test
func inputSenderAccumulatesQueuedRelativeMouseMoves() async throws {
    let transport = RecordingInputTransport()
    let sender = InputSender(
        context: InputEncodingContext(hostKind: .sunshine),
        transport: transport
    )

    try await sender.send(.mouse(.relativeMove(dx: 3, dy: 4)))
    try await sender.send(.mouse(.relativeMove(dx: -1, dy: 2)))
    try await sender.flushPendingMouseMotion()

    let packets = await transport.recordedPackets()
    #expect(packets.count == 1)
    #expect(packets[0].packet.hexString == "000000080700000000020006")
    #expect(packets[0].channelID == ControlChannelID.mouse)
    #expect(packets[0].reliable)
}

@Test
func inputSenderSplitsOversizedCoalescedRelativeMouseMoves() async throws {
    let transport = RecordingInputTransport()
    let sender = InputSender(
        context: InputEncodingContext(hostKind: .sunshine),
        transport: transport
    )

    try await sender.send(.mouse(.relativeMove(dx: .max, dy: 0)))
    try await sender.send(.mouse(.relativeMove(dx: .max, dy: 0)))
    try await sender.flushPendingMouseMotion()

    let packets = await transport.recordedPackets()
    #expect(packets.count == 2)
    #expect(packets[0].packet.hexString == "00000008070000007FFF0000")
    #expect(packets[1].packet.hexString == "00000008070000007FFF0000")
    #expect(packets.allSatisfy { $0.channelID == ControlChannelID.mouse })
    #expect(packets.allSatisfy { $0.reliable })
}

@Test
func inputSenderMetricsTrackPacketsAndLatencies() async throws {
    let transport = RecordingInputTransport()
    let sender = InputSender(
        context: InputEncodingContext(hostKind: .sunshine),
        transport: transport,
        configuration: .init(mouseMotionDeliveryPolicy: .coalesced(interval: .seconds(3600)))
    )

    try await sender.send(.mouse(.relativeMove(dx: 4, dy: 0)))
    try await sender.send(.mouse(.relativeMove(dx: 6, dy: 0)))
    try await sender.flushPendingInput()
    try await sender.send(.keyboard(.keyDown(.space)))

    let metrics = await sender.snapshotInputMetrics()

    #expect(metrics.inputPacketsSent == 2)
    #expect(metrics.averageInputQueueLatencyMs != nil)
    #expect(metrics.maxInputQueueLatencyMs != nil)
    #expect(metrics.averageInputTransportLatencyMs != nil)
    #expect(metrics.maxInputTransportLatencyMs != nil)
}

@Test
func inputSenderFlushesPendingMouseMotionBeforeButtonPackets() async throws {
    let transport = RecordingInputTransport()
    let sender = InputSender(
        context: InputEncodingContext(
            hostKind: .sunshine,
            absoluteReferenceWidth: 640,
            absoluteReferenceHeight: 360
        ),
        transport: transport
    )

    try await sender.send(.mouse(.absoluteMove(x: 0.1, y: 0.2)))
    try await sender.send(.mouse(.absoluteMove(x: 0.5, y: 0.25)))
    try await sender.send(.mouse(.button(button: .left, state: .pressed)))

    let packets = await transport.recordedPackets()
    #expect(packets.count == 2)
    #expect(packets[0].packet.hexString == "0000000C050000000140005A0000027F0167")
    #expect(packets[0].channelID == ControlChannelID.mouse)
    #expect(packets[1].packet.hexString == "000000050800000001")
    #expect(packets[1].channelID == ControlChannelID.mouse)
}

@Test
func sessionSendUsesAttachedInputSender() async throws {
    let session = MoonlightSession()
    let transport = RecordingInputTransport()
    let sender = InputSender(
        context: InputEncodingContext(hostKind: .sunshine),
        transport: transport
    )

    await session.attachInputSender(sender)
    try await session.send(.mouse(.button(button: .left, state: .pressed)))

    let packets = await transport.recordedPackets()
    #expect(packets.count == 1)
    #expect(packets[0].packet.hexString == "000000050800000001")
    #expect(packets[0].channelID == ControlChannelID.mouse)
    #expect(packets[0].reliable)
}

@Test
func sessionFlushPendingInputFlushesAttachedInputSender() async throws {
    let session = MoonlightSession()
    let transport = RecordingInputTransport()
    let sender = InputSender(
        context: InputEncodingContext(
            hostKind: .sunshine,
            absoluteReferenceWidth: 640,
            absoluteReferenceHeight: 360
        ),
        transport: transport,
        configuration: .init(mouseMotionDeliveryPolicy: .coalesced(interval: .seconds(3600)))
    )

    await session.attachInputSender(sender)
    try await session.send(.mouse(.absoluteMove(x: 0.25, y: 0.5)))
    try await session.send(.mouse(.absoluteMove(x: 0.5, y: 0.25)))

    #expect(await transport.recordedPackets().isEmpty)

    try await session.flushPendingInput()

    let packets = await transport.recordedPackets()
    #expect(packets.count == 1)
    #expect(packets[0].packet.hexString == "0000000C050000000140005A0000027F0167")
    #expect(packets[0].channelID == ControlChannelID.mouse)
    #expect(packets[0].reliable)

    let metrics = await session.currentMetricsSnapshot()
    #expect(metrics.inputEventsSent == 2)
    #expect(metrics.inputPacketsSent == 1)
    #expect(metrics.averageInputQueueLatencyMs != nil)
    #expect(metrics.averageInputTransportLatencyMs != nil)
}

@Test
func sessionStopFlushesPendingInputBeforeStopping() async throws {
    let session = MoonlightSession()
    let transport = RecordingInputTransport()
    let sender = InputSender(
        context: InputEncodingContext(
            hostKind: .sunshine,
            absoluteReferenceWidth: 640,
            absoluteReferenceHeight: 360
        ),
        transport: transport,
        configuration: .init(mouseMotionDeliveryPolicy: .coalesced(interval: .seconds(3600)))
    )

    await session.attachInputSender(sender)
    try await session.send(.mouse(.absoluteMove(x: 0.5, y: 0.25)))
    await session.stop()

    let packets = await transport.recordedPackets()
    #expect(packets.count == 1)
    #expect(packets[0].packet.hexString == "0000000C050000000140005A0000027F0167")

    await #expect(throws: MoonlightError.self) {
        try await session.flushPendingInput()
    }
}
