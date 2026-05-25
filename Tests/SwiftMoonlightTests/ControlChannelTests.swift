import Foundation
import Testing
@testable import SwiftMoonlight

@Test
func decodesRumblePacket() throws {
    let parser = ControlMessageParser()
    let packet = try #require(Data(hexString: "0B0100000000010022114433"))

    let message = try parser.parse(packet: packet)

    #expect(message == .rumble(.init(
        controllerNumber: 1,
        lowFrequencyMotor: 0x1122,
        highFrequencyMotor: 0x3344
    )))
}

@Test
func decodesTriggerRumblePacket() throws {
    let parser = ControlMessageParser()
    let packet = try #require(Data(hexString: "0055030010002000"))

    let message = try parser.parse(packet: packet)

    #expect(message == .rumbleTriggers(.init(
        controllerNumber: 3,
        leftTriggerMotor: 16,
        rightTriggerMotor: 32
    )))
}

@Test
func decodesMotionAndLedPackets() throws {
    let parser = ControlMessageParser()
    let motionPacket = try #require(Data(hexString: "01550200280002"))
    let ledPacket = try #require(Data(hexString: "02550400102030"))

    let motion = try parser.parse(packet: motionPacket)
    let led = try parser.parse(packet: ledPacket)

    #expect(motion == .setMotionEventState(.init(
        controllerNumber: 2,
        motionType: 2,
        reportRateHz: 40
    )))
    #expect(led == .setControllerLED(.init(
        controllerNumber: 4,
        red: 0x10,
        green: 0x20,
        blue: 0x30
    )))
}

@Test
func decodesAdaptiveTriggerPacket() throws {
    let parser = ControlMessageParser()
    let packet = Data([
        0x03, 0x55,
        0x01, 0x00,
        0x0C,
        0x01,
        0x02,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A,
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A,
    ])

    let message = try parser.parse(packet: packet)

    #expect(message == .adaptiveTriggers(.init(
        controllerNumber: 1,
        eventFlags: 0x0C,
        leftTriggerType: 0x01,
        rightTriggerType: 0x02,
        leftPayload: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
        rightPayload: [0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A]
    )))
}

@Test
func decodesHDRPacketWithMetadata() throws {
    let parser = ControlMessageParser()
    let packet = try #require(Data(hexString:
        "0E0101" +
        "6400C8002C019001F4015802" +
        "BC022003" +
        "E8030A0014001E002800"
    ))

    let message = try parser.parse(packet: packet)

    #expect(message == .hdrModeChanged(.init(
        enabled: true,
        metadata: HDRMetadata(
            displayPrimaries: [
                .init(x: 100, y: 200),
                .init(x: 300, y: 400),
                .init(x: 500, y: 600),
            ],
            whitePoint: .init(x: 700, y: 800),
            maxDisplayLuminance: 1000,
            minDisplayLuminance: 10,
            maxContentLightLevel: 20,
            maxFrameAverageLightLevel: 30,
            maxFullFrameLuminance: 40
        )
    )))
}

@Test
func decodesTerminationAndNormalizesKnownReasons() throws {
    let parser = ControlMessageParser()
    let protectedContent = try #require(Data(hexString: "0901800E9302"))
    let graceful = try #require(Data(hexString: "09010001"))

    let protectedMessage = try parser.parse(packet: protectedContent)
    let gracefulMessage = try parser.parse(packet: graceful, context: .init(hasReceivedVideoFrame: true))

    #expect(protectedMessage == .terminated(.init(
        rawCode: 0x800E9302,
        reason: .protectedContent
    )))
    #expect(gracefulMessage == .terminated(.init(
        rawCode: 0x0100,
        reason: .graceful
    )))
}

@Test
func shortTerminationBeforeFramesMapsToUnexpectedEarly() throws {
    let parser = ControlMessageParser()
    let packet = try #require(Data(hexString: "09010001"))

    let message = try parser.parse(packet: packet, context: .init(hasReceivedVideoFrame: false))

    #expect(message == .terminated(.init(
        rawCode: 0x0100,
        reason: .unexpectedEarly
    )))
}

@Test
func controlServiceReceivesAndSendsPackets() async throws {
    let transport = RecordingControlChannelTransport(receivedPackets: [
        try #require(Data(hexString: "015501001E0001"))
    ])
    let service = ControlChannelService(transport: transport, logger: TestLogger())

    let message = try await service.receiveNextMessage()
    try await service.send(packet: Data([0xAA, 0xBB]), channelID: ControlChannelID.urgent, reliable: false)

    #expect(message == .setMotionEventState(.init(
        controllerNumber: 1,
        motionType: 1,
        reportRateHz: 30
    )))

    let sent = await transport.recordedSentPackets()
    #expect(sent.count == 1)
    #expect(sent[0].packet == Data([0xAA, 0xBB]))
    #expect(sent[0].channelID == ControlChannelID.urgent)
    #expect(sent[0].reliable == false)
}

@Test
func controlServiceReportsTransportMetricsWhenAvailable() async throws {
    let metrics = ControlTransportMetricsSnapshot(
        isConnected: true,
        roundTripTimeMs: 12,
        roundTripTimeVarianceMs: 3,
        packetLossRatio: 0.01,
        packetLossVarianceRatio: 0.002
    )
    let transport = RecordingMetricsControlChannelTransport(metrics: metrics)
    let service = ControlChannelService(transport: transport, logger: TestLogger())

    let snapshot = await service.snapshotTransportMetrics()

    #expect(snapshot == metrics)
}

@Test
func enetPeriodicPingMatchesMoonlightShape() {
    #expect(ENetControlSession.periodicPingUsesReliableDelivery)
    #expect(ENetControlSession.makePeriodicPingPayload() == Data([0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]))
}

@Test
func controlServiceSendsIDRRequestOnUrgentChannel() async throws {
    let transport = RecordingControlChannelTransport()
    let service = ControlChannelService(transport: transport, logger: TestLogger())

    try await service.requestIDRFrame()

    let sent = await transport.recordedSentPackets()
    #expect(sent.count == 1)
    #expect(sent[0].packet == Data([0x02, 0x03, 0x00, 0x00]))
    #expect(sent[0].channelID == ControlChannelID.urgent)
    #expect(sent[0].reliable)
}

@Test
func controlEncoderBuildsFrameFECStatusPacket() throws {
    let encoder = ControlPacketEncoder()
    let packet = encoder.frameFECStatusPacket(.init(
        frameIndex: 0x0102_0304,
        highestReceivedSequenceNumber: 0x1122,
        nextContiguousSequenceNumber: 0x3344,
        missingPacketsBeforeHighestReceived: 0x0002,
        totalDataPackets: 0x000A,
        totalParityPackets: 0x0002,
        receivedDataPackets: 0x0008,
        receivedParityPackets: 0x0001,
        fecPercentage: 20,
        multiFecBlockIndex: 1,
        multiFecBlockCount: 2
    ))

    #expect(packet.hexString == "025501020304112233440002000A000200080001140102")
}

@Test
func controlServiceSendsFrameFECStatusOnGenericUnreliableChannel() async throws {
    let transport = RecordingControlChannelTransport()
    let service = ControlChannelService(transport: transport, logger: TestLogger())

    try await service.sendFrameFECStatus(.init(
        frameIndex: 7,
        highestReceivedSequenceNumber: 12,
        nextContiguousSequenceNumber: 10,
        missingPacketsBeforeHighestReceived: 2,
        totalDataPackets: 3,
        totalParityPackets: 1,
        receivedDataPackets: 2,
        receivedParityPackets: 0,
        fecPercentage: 20,
        multiFecBlockIndex: 0,
        multiFecBlockCount: 1
    ))

    let sent = await transport.recordedSentPackets()
    #expect(sent.count == 1)
    #expect(sent[0].packet.hexString == "025500000007000C000A00020003000100020000140001")
    #expect(sent[0].channelID == ControlChannelID.generic)
    #expect(sent[0].reliable == false)
}
