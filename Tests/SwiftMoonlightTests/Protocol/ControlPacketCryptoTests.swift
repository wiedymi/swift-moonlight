import Foundation
import Testing
@testable import SwiftMoonlight

@Test
func roundTripsEncryptedControlPacketV2() throws {
    let crypto = ControlPacketCrypto()
    let context = ControlEncryptionContext(
        key: Data(repeating: 0x11, count: 16),
        version: .v2
    )
    let payload = try #require(Data(hexString: "00000000010022114433"))

    let encrypted = try crypto.seal(
        packetType: ControlPacketType.rumble.rawValue,
        payload: payload,
        sequenceNumber: 7,
        sender: .host,
        context: context
    )
    let decrypted = try crypto.open(
        packet: encrypted,
        sender: .host,
        context: context
    )

    #expect(decrypted.sequenceNumber == 7)
    #expect(decrypted.packetType == ControlPacketType.rumble.rawValue)
    #expect(decrypted.payload == payload)
    #expect(decrypted.packet.hexString == "0B0100000000010022114433")
}

@Test
func controlServiceDecodesEncryptedIncomingPacket() async throws {
    let cryptoContext = ControlEncryptionContext(
        key: Data(repeating: 0x5A, count: 16),
        version: .v2
    )
    let crypto = ControlPacketCrypto()
    let payload = try #require(Data(hexString: "010000"))
    let encrypted = try crypto.seal(
        packetType: ControlPacketType.hdrMode.rawValue,
        payload: payload,
        sequenceNumber: 99,
        sender: .host,
        context: cryptoContext
    )

    let transport = RecordingControlChannelTransport(receivedPackets: [encrypted])
    let service = ControlChannelService(transport: transport, logger: TestLogger())
    let message = try await service.receiveNextEncryptedMessage(encryption: cryptoContext)

    #expect(message == .hdrModeChanged(.init(enabled: true, metadata: nil)))
}

@Test
func serviceSendsEncryptedPacketOnUrgentChannel() async throws {
    let cryptoContext = ControlEncryptionContext(
        key: Data(repeating: 0x22, count: 16),
        version: .v2
    )
    let transport = RecordingControlChannelTransport()
    let service = ControlChannelService(transport: transport, logger: TestLogger())

    try await service.sendEncrypted(
        packetType: ControlPacketType.setMotionEventState.rawValue,
        payload: try #require(Data(hexString: "01001E0002")),
        sequenceNumber: 5,
        channelID: ControlChannelID.urgent,
        reliable: false,
        encryption: cryptoContext
    )

    let sent = await transport.recordedSentPackets()
    #expect(sent.count == 1)
    #expect(sent[0].channelID == ControlChannelID.urgent)
    #expect(sent[0].reliable == false)

    let decrypted = try ControlPacketCrypto().open(
        packet: sent[0].packet,
        sender: .client,
        context: cryptoContext
    )
    #expect(decrypted.packetType == ControlPacketType.setMotionEventState.rawValue)
    #expect(decrypted.payload.hexString == "01001E0002")
}

@Test
func highLevelEncryptedControlPacketsUseMonotonicSequences() async throws {
    let cryptoContext = ControlEncryptionContext(
        key: Data(repeating: 0x33, count: 16),
        version: .v2
    )
    let transport = RecordingControlChannelTransport()
    let service = ControlChannelService(transport: transport, logger: TestLogger())

    try await service.sendFrameFECStatus(.init(
        frameIndex: 1,
        highestReceivedSequenceNumber: 3,
        nextContiguousSequenceNumber: 2,
        missingPacketsBeforeHighestReceived: 1,
        totalDataPackets: 2,
        totalParityPackets: 1,
        receivedDataPackets: 1,
        receivedParityPackets: 1,
        fecPercentage: 50,
        multiFecBlockIndex: 0,
        multiFecBlockCount: 1
    ), encryption: cryptoContext)
    try await service.requestIDRFrame(encryption: cryptoContext)

    let sent = await transport.recordedSentPackets()
    #expect(sent.count == 2)
    let first = try ControlPacketCrypto().open(
        packet: sent[0].packet,
        sender: .client,
        context: cryptoContext
    )
    let second = try ControlPacketCrypto().open(
        packet: sent[1].packet,
        sender: .client,
        context: cryptoContext
    )

    #expect(first.sequenceNumber == 0)
    #expect(first.packetType == ControlPacketEncoder.frameFECStatusPacketType)
    #expect(second.sequenceNumber == 1)
    #expect(second.packetType == ControlPacketType.requestIDRFrame.rawValue)
}
