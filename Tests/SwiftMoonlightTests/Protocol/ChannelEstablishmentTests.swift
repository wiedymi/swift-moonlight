import Foundation
import Testing
@testable import SwiftMoonlight

@Test
func buildsChannelPlanForFullSession() {
    let negotiation = RTSPNegotiationResult(
        sessionID: "DEADBEEFCAFE",
        audio: .init(sessionID: "DEADBEEFCAFE", serverPort: 48000, pingPayload: "AUDPING0"),
        video: .init(sessionID: "DEADBEEFCAFE", serverPort: 47998, pingPayload: "VIDPING0"),
        control: .init(sessionID: "DEADBEEFCAFE", serverPort: 47999, controlConnectData: 0x1234)
    )

    let plan = ChannelPlanBuilder().buildPlan(from: negotiation, isInputOnly: false)

    #expect(plan.descriptors.count == 4)
    #expect(plan.descriptors[0].kind == .control)
    #expect(plan.descriptors[1].kind == .input)
    #expect(plan.descriptors[2].kind == .video)
    #expect(plan.descriptors[3].kind == .audio)
}

@Test
func buildsChannelPlanForInputOnlySession() {
    let negotiation = RTSPNegotiationResult(
        sessionID: "DEADBEEFCAFE",
        audio: .init(sessionID: "DEADBEEFCAFE", serverPort: 48000),
        video: .init(sessionID: "DEADBEEFCAFE", serverPort: 47998),
        control: .init(sessionID: "DEADBEEFCAFE", serverPort: 47999)
    )

    let plan = ChannelPlanBuilder().buildPlan(from: negotiation, isInputOnly: true)

    #expect(plan.descriptors.count == 2)
    #expect(plan.descriptors[0].kind == .control)
    #expect(plan.descriptors[1].kind == .input)
}

@Test
func establishesChannelsInPlannedOrder() async throws {
    let host = MoonlightHost(
        id: HostID(),
        name: "Sunshine",
        endpoint: .init(address: "192.168.1.10", port: 47989),
        kind: .sunshine,
        pairingState: .paired,
        capabilities: .default
    )
    let negotiation = RTSPNegotiationResult(
        sessionID: "DEADBEEFCAFE",
        audio: .init(sessionID: "DEADBEEFCAFE", serverPort: 48000, pingPayload: "AUDPING0"),
        video: .init(sessionID: "DEADBEEFCAFE", serverPort: 47998, pingPayload: "VIDPING0"),
        control: .init(sessionID: "DEADBEEFCAFE", serverPort: 47999, controlConnectData: 0x1234)
    )
    let transport = RecordingChannelTransport()
    let service = ChannelEstablishmentService(transport: transport)

    let channels = try await service.establish(host: host, negotiation: negotiation, isInputOnly: false)
    let requests = await transport.recordedRequests()

    #expect(channels.count == 4)
    #expect(requests.map(\.descriptor.kind) == [.control, .input, .video, .audio])
}

@Test
func channelProbeBuilderBuildsSunshinePingPacket() throws {
    let descriptor = ChannelDescriptor(
        kind: .video,
        port: 47998,
        metadata: ["pingPayload": "1234567890abcdef"]
    )

    let probe = try ChannelProbeBuilder().makeProbe(for: descriptor)

    #expect(probe == Data("1234567890abcdef".utf8) + Data([0, 0, 0, 0]))
}

@Test
func channelProbeBuilderFallsBackToLegacyPingPacket() throws {
    let descriptor = ChannelDescriptor(
        kind: .audio,
        port: 48000,
        metadata: [:]
    )

    let probe = try ChannelProbeBuilder().makeProbe(for: descriptor)

    #expect(probe == Data("PING".utf8))
}

@Test
func udpChannelPacketSourceIncrementsSunshinePingSequence() async throws {
    let receiver = try UDPPacketSource(bindHost: "127.0.0.1", port: 0)
    defer {
        Task {
            await receiver.stop()
        }
    }
    let socket = try BoundUDPSocket(
        remoteHost: "127.0.0.1",
        remotePort: await receiver.localPort()
    )
    let source = UDPChannelPacketSource(
        socket: socket,
        keepalivePacket: Data("1234567890abcdef".utf8) + Data([0, 0, 0, 0])
    )

    let firstPacket = try await receiver.receivePacket()
    let secondPacket = try await receiver.receivePacket()

    #expect(firstPacket == Data("1234567890abcdef".utf8) + Data([0, 0, 0, 1]))
    #expect(secondPacket == Data("1234567890abcdef".utf8) + Data([0, 0, 0, 2]))
    await source.close()
}

@Test
func udpChannelTransportSendsVideoProbePacket() async throws {
    let source = try UDPPacketSource(bindHost: "127.0.0.1", port: 0)
    defer {
        Task {
            await source.stop()
        }
    }

    let host = MoonlightHost(
        id: HostID(),
        name: "Loopback",
        endpoint: .init(address: "127.0.0.1", port: 47989),
        kind: .sunshine,
        pairingState: .paired,
        capabilities: .default
    )
    let descriptor = ChannelDescriptor(
        kind: .video,
        port: await source.localPort(),
        metadata: ["pingPayload": "1234567890abcdef"]
    )

    let channel = try await UDPChannelTransport().establishChannel(to: host, descriptor: descriptor)
    let packet = try await source.receivePacket()

    #expect(channel.isConnected)
    #expect(packet == Data("1234567890abcdef".utf8) + Data([0, 0, 0, 0]))
}
