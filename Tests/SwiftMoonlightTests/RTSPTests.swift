import Foundation
import Testing
@testable import SwiftMoonlight
#if canImport(Network)
import Network
#endif

private actor IntCapture {
    private var value: Int = -1

    func store(_ value: Int) {
        self.value = value
    }

    func load() -> Int {
        value
    }
}

@Test
func parsesRTSPResponseAndHeaders() throws {
    let raw = Data((
        "RTSP/1.0 200 OK\r\n" +
        "CSeq: 3\r\n" +
        "Session: DEADBEEFCAFE;timeout=90\r\n" +
        "Transport: unicast;server_port=48000-48001;source=192.168.1.10\r\n" +
        "X-SS-Ping-Payload: ABCDEFGH\r\n" +
        "\r\n"
    ).utf8)

    let message = try RTSPMessageParser().parse(raw)

    guard case let .response(response) = message else {
        Issue.record("Expected RTSP response")
        return
    }

    #expect(response.statusCode == 200)
    #expect(response.statusText == "OK")
    #expect(response.headers.count == 4)
    #expect(message.headerValue(named: "Session") == "DEADBEEFCAFE;timeout=90")
}

@Test
func serializesRTSPDescribeRequest() {
    let request = RTSPRequestFactory().describe(url: "rtsp://192.168.1.10:47998", cSeq: 1)
    let text = String(decoding: request.serialized(), as: UTF8.self)

    #expect(text.contains("DESCRIBE rtsp://192.168.1.10:47998 RTSP/1.0"))
    #expect(text.contains("CSeq: 1"))
    #expect(text.contains("Host: 192.168.1.10:47998"))
    #expect(text.contains("X-GS-ClientVersion: 14"))
    #expect(text.contains("Accept: application/sdp"))
}

@Test
func serializesRTSPOptionsRequest() {
    let request = RTSPRequestFactory().options(url: "rtsp://192.168.1.10:47998", cSeq: 1)
    let text = String(decoding: request.serialized(), as: UTF8.self)

    #expect(text.contains("OPTIONS rtsp://192.168.1.10:47998 RTSP/1.0"))
    #expect(text.contains("Host: 192.168.1.10:47998"))
    #expect(text.contains("X-GS-ClientVersion: 14"))
}

@Test
func extractsSessionInfoFromSetupResponse() throws {
    let raw = Data((
        "RTSP/1.0 200 OK\r\n" +
        "CSeq: 2\r\n" +
        "Session: DEADBEEFCAFE;timeout=90\r\n" +
        "Transport: unicast;server_port=47998-47999;source=192.168.1.10\r\n" +
        "X-SS-Ping-Payload: ABCDEFGH\r\n" +
        "X-SS-Connect-Data: 0x1234\r\n" +
        "\r\n"
    ).utf8)

    let message = try RTSPMessageParser().parse(raw)
    guard case let .response(response) = message else {
        Issue.record("Expected RTSP response")
        return
    }

    let info = RTSPSessionInfoParser().parseSetupResponse(response)
    #expect(info.sessionID == "DEADBEEFCAFE")
    #expect(info.serverPort == 47998)
    #expect(info.pingPayload == "ABCDEFGH")
    #expect(info.controlConnectData == 0x1234)
}

@Test
func parsesSunshineDescribeEncryptionFlags() {
    let response = RTSPResponse(
        statusCode: 200,
        statusText: "OK",
        body: Data("""
        v=0
        a=x-ss-general.encryptionSupported:7
        a=x-ss-general.encryptionRequested:4
        """.replacingOccurrences(of: "\n", with: "\r\n").utf8)
    )

    let info = RTSPDescribeInfoParser().parseDescribeResponse(response)

    #expect(info.encryptionSupported == [.controlV2, .video, .audio])
    #expect(info.encryptionRequested == [.audio])
}

@Test
func parsesOpusSurroundConfigurationAndAppliesMoonlightRemap() throws {
    let sdp = """
    v=0
    a=fmtp:97 surround-params=642041235
    """

    let config = try OpusConfigurationParser().parse(sdp: sdp, audioMode: .surround51)

    #expect(config.channelCount == 6)
    #expect(config.streams == 4)
    #expect(config.coupledStreams == 2)
    #expect(config.mapping == [0, 4, 1, 5, 2, 3])
}

@Test
func buildsUnifiedRTSPSessionPlan() {
    let builder = RTSPRequestPlanBuilder()
    let plan = builder.buildPlan(
        sessionURL: "rtsp://192.168.1.10:47998",
        sessionID: "DEADBEEFCAFE",
        sdp: Data("v=0\r\n".utf8),
        useUnifiedPlay: true,
        includeControlStream: true
    )

    #expect(plan.describeRequest.method == .describe)
    #expect(plan.optionsRequest.method == .options)
    #expect(plan.audioSetupRequest.target == "streamid=audio/0/0")
    #expect(plan.videoSetupRequest.target == "streamid=video/0/0")
    #expect(plan.controlSetupRequest?.target == "streamid=control/13/0")
    #expect(plan.announceRequest.method == .announce)
    #expect(plan.playRequests.count == 1)
    #expect(plan.playRequests[0].target == "/")
}

@Test
func buildsLegacyRTSPPlayPlan() {
    let builder = RTSPRequestPlanBuilder()
    let plan = builder.buildPlan(
        sessionURL: "rtsp://192.168.1.10:47998",
        sessionID: "DEADBEEFCAFE",
        sdp: Data("v=0\r\n".utf8),
        useUnifiedPlay: false,
        includeControlStream: false
    )

    #expect(plan.controlSetupRequest == nil)
    #expect(plan.playRequests.count == 2)
    #expect(plan.playRequests[0].target == "streamid=video")
    #expect(plan.playRequests[1].target == "streamid=audio")
}

@Test
func negotiatesRTSPSessionFromFixtureResponses() async throws {
    let transport = FixtureRTSPTransport(responses: [
        RTSPResponse(statusCode: 200, statusText: "OK"),
        RTSPResponse(statusCode: 200, statusText: "OK"),
        RTSPResponse(
            statusCode: 200,
            statusText: "OK",
            headers: [
                .init(name: "Session", value: "DEADBEEFCAFE;timeout=90"),
                .init(name: "Transport", value: "unicast;server_port=48000-48001;source=192.168.1.10"),
                .init(name: "X-SS-Ping-Payload", value: "AUDPING0"),
            ]
        ),
        RTSPResponse(
            statusCode: 200,
            statusText: "OK",
            headers: [
                .init(name: "Transport", value: "unicast;server_port=47998-47999;source=192.168.1.10"),
                .init(name: "X-SS-Ping-Payload", value: "VIDPING0"),
            ]
        ),
        RTSPResponse(
            statusCode: 200,
            statusText: "OK",
            headers: [
                .init(name: "Transport", value: "unicast;server_port=47999-48000;source=192.168.1.10"),
                .init(name: "X-SS-Connect-Data", value: "0x1234"),
            ]
        ),
        RTSPResponse(statusCode: 200, statusText: "OK"),
        RTSPResponse(statusCode: 200, statusText: "OK"),
    ])
    let service = RTSPNegotiationService(transport: transport)

    let result = try await service.negotiate(sessionURL: "rtsp://192.168.1.10:47998")
    let requests = await transport.recordedRequests()

    #expect(result.sessionID == "DEADBEEFCAFE")
    #expect(result.audio.serverPort == 48000)
    #expect(result.video.serverPort == 47998)
    #expect(result.control?.serverPort == 47999)
    #expect(result.control?.controlConnectData == 0x1234)
    #expect(result.describeInfo.encryptionSupported == [])
    #expect(requests.count == 7)
    #expect(requests[0].method == .options)
    #expect(requests[1].method == .describe)
    #expect(requests[2].method == .setup)
    #expect(requests[5].method == .announce)
    #expect(requests[6].method == .play)
}

@Test
func negotiateInvokesPrePlayCallbackBeforeAnnounceAndPlay() async throws {
    let transport = FixtureRTSPTransport(responses: [
        RTSPResponse(statusCode: 200, statusText: "OK"),
        RTSPResponse(statusCode: 200, statusText: "OK"),
        RTSPResponse(statusCode: 200, statusText: "OK", headers: [
            .init(name: "Session", value: "DEADBEEFCAFE;timeout=90"),
            .init(name: "Transport", value: "unicast;server_port=48000-48001"),
        ]),
        RTSPResponse(statusCode: 200, statusText: "OK", headers: [
            .init(name: "Transport", value: "unicast;server_port=47998-47999"),
        ]),
        RTSPResponse(statusCode: 200, statusText: "OK", headers: [
            .init(name: "Transport", value: "unicast;server_port=47999-48000"),
        ]),
        RTSPResponse(statusCode: 200, statusText: "OK"),
        RTSPResponse(statusCode: 200, statusText: "OK"),
    ])
    let service = RTSPNegotiationService(transport: transport)
    let capture = IntCapture()

    _ = try await service.negotiate(
        sessionURL: "rtsp://192.168.1.10:47998",
        prePlay: { _ in
            await capture.store(await transport.recordedRequests().count)
        }
    )

    let requests = await transport.recordedRequests()
    #expect(await capture.load() == 5)
    #expect(requests[5].method == .announce)
    #expect(requests[6].method == .play)
}

@Test
func negotiateInvokesAudioSetupCallbackBeforeVideoSetup() async throws {
    let transport = FixtureRTSPTransport(responses: [
        RTSPResponse(statusCode: 200, statusText: "OK"),
        RTSPResponse(statusCode: 200, statusText: "OK"),
        RTSPResponse(statusCode: 200, statusText: "OK", headers: [
            .init(name: "Session", value: "DEADBEEFCAFE;timeout=90"),
            .init(name: "Transport", value: "unicast;server_port=48000-48001"),
            .init(name: "X-SS-Ping-Payload", value: "audpingpayload01"),
        ]),
        RTSPResponse(statusCode: 200, statusText: "OK", headers: [
            .init(name: "Transport", value: "unicast;server_port=47998-47999"),
        ]),
        RTSPResponse(statusCode: 200, statusText: "OK", headers: [
            .init(name: "Transport", value: "unicast;server_port=47999-48000"),
        ]),
        RTSPResponse(statusCode: 200, statusText: "OK"),
        RTSPResponse(statusCode: 200, statusText: "OK"),
    ])
    let service = RTSPNegotiationService(transport: transport)
    let requestCountCapture = IntCapture()
    let audioPortCapture = IntCapture()

    _ = try await service.negotiate(
        sessionURL: "rtsp://192.168.1.10:47998",
        afterAudioSetup: { audioInfo, _ in
            await requestCountCapture.store(await transport.recordedRequests().count)
            await audioPortCapture.store(Int(audioInfo.serverPort ?? 0))
        }
    )

    #expect(await requestCountCapture.load() == 3)
    #expect(await audioPortCapture.load() == 48000)
}

@Test
func encryptedRTSPCodecRoundTripsHostResponses() throws {
    let crypto = RTSPMessageCrypto()
    let key = Data(repeating: 0x11, count: 16)
    let plaintext = Data("RTSP/1.0 200 OK\r\nCSeq: 1\r\n\r\n".utf8)

    let packet = try crypto.encrypt(plaintext, key: key, sequenceNumber: 9, direction: .hostToClient)
    let envelope = try EncryptedRTSPEnvelope.parse(from: packet)
    let decrypted = try crypto.decrypt(packet, key: key, direction: .hostToClient)

    #expect(envelope.sequenceNumber == 9)
    #expect(decrypted == plaintext)
}

@Test
func buildsAnnounceSDPThatIncludesRequiredSunshineFields() {
    let sdp = String(decoding: RTSPAnnounceSDPBuilder().build(for: .default1080p60), as: UTF8.self)

    #expect(sdp.contains("v=0\r\n"))
    #expect(sdp.contains("s=stream\r\n"))
    #expect(sdp.contains("a=x-ml-general.featureFlags:3\r\n"))
    #expect(sdp.contains("a=x-nv-general.featureFlags:679\r\n"))
    #expect(sdp.contains("a=x-nv-general.useReliableUdp:13\r\n"))
    #expect(sdp.contains("a=x-nv-vqos[0].fec.minRequiredFecPackets:2\r\n"))
    #expect(sdp.contains("a=x-nv-vqos[0].bllFec.enable:0\r\n"))
    #expect(sdp.contains("a=x-nv-vqos[0].drc.enable:0\r\n"))
    #expect(sdp.contains("a=x-nv-general.enableRecoveryMode:0\r\n"))
    #expect(sdp.contains("a=x-ss-general.encryptionEnabled:7\r\n"))
    #expect(sdp.contains("a=x-ss-video[0].chromaSamplingType:0\r\n"))
    #expect(sdp.contains("a=x-ss-video[0].intraRefresh:0\r\n"))
    #expect(sdp.contains("a=x-nv-audio.surround.numChannels:2\r\n"))
    #expect(sdp.contains("a=x-nv-audio.surround.channelMask:3\r\n"))
    #expect(sdp.contains("a=x-nv-audio.surround.enable:0\r\n"))
    #expect(sdp.contains("a=x-nv-audio.surround.AudioQuality:0\r\n"))
    #expect(sdp.contains("a=x-nv-aqos.packetDuration:5\r\n"))
    #expect(sdp.contains("a=x-nv-aqos.qosTrafficType:4\r\n"))
    #expect(sdp.contains("a=x-nv-video[0].packetSize:1360\r\n"))
    #expect(sdp.contains("a=x-nv-video[0].clientViewportWd:1920\r\n"))
    #expect(sdp.contains("a=x-nv-video[0].clientViewportHt:1080\r\n"))
    #expect(sdp.contains("a=x-nv-video[0].maxFPS:60\r\n"))
    #expect(sdp.contains("a=x-nv-video[0].rateControlMode:4\r\n"))
    #expect(sdp.contains("a=x-nv-video[0].timeoutLengthMs:7000\r\n"))
    #expect(sdp.contains("a=x-nv-video[0].framesWithInvalidRefThreshold:0\r\n"))
    #expect(sdp.contains("a=x-nv-vqos[0].fec.enable:1\r\n"))
    #expect(sdp.contains("a=x-nv-vqos[0].videoQualityScoreUpdateTime:5000\r\n"))
    #expect(sdp.contains("a=x-nv-vqos[0].qosTrafficType:5\r\n"))
    #expect(sdp.contains("a=x-ml-video.configuredBitrateKbps:20000\r\n"))
    #expect(sdp.contains("a=x-nv-video[0].initialBitrateKbps:20000\r\n"))
    #expect(sdp.contains("a=x-nv-video[0].initialPeakBitrateKbps:20000\r\n"))
    #expect(sdp.contains("a=x-nv-vqos[0].bw.minimumBitrateKbps:20000\r\n"))
    #expect(sdp.contains("a=x-nv-vqos[0].bw.maximumBitrateKbps:20000\r\n"))
    #expect(sdp.contains("a=x-nv-video[0].videoEncoderSlicesPerFrame:1\r\n"))
    #expect(sdp.contains("a=x-nv-video[0].maxNumReferenceFrames:1\r\n"))
    #expect(sdp.contains("a=x-nv-video[0].clientRefreshRateX100:6000\r\n"))
    #expect(sdp.contains("a=x-nv-video[0].dynamicRangeMode:0\r\n"))
    #expect(sdp.contains("a=x-nv-video[0].encoderCscMode:0\r\n"))
    #expect(sdp.contains("a=x-nv-clientSupportHevc:1\r\n"))
    #expect(sdp.contains("a=x-nv-vqos[0].bitStreamFormat:1\r\n"))
}

@Test
func announceSDPUsesBasePacketSizeWhenVideoEncryptionIsDisabled() {
    var configuration = StreamConfiguration.default1080p60
    configuration.enableVideoEncryption = false

    let sdp = String(decoding: RTSPAnnounceSDPBuilder().build(for: configuration), as: UTF8.self)

    #expect(sdp.contains("a=x-ss-general.encryptionEnabled:5\r\n"))
    #expect(sdp.contains("a=x-nv-video[0].packetSize:1392\r\n"))
}

@Test
func announceSDPRequestsH264WhenConfiguredAsFirstPreference() {
    var configuration = StreamConfiguration.default1080p60
    configuration.videoCodecPreference = [.h264]

    let sdp = String(decoding: RTSPAnnounceSDPBuilder().build(for: configuration), as: UTF8.self)

    #expect(sdp.contains("a=x-nv-clientSupportHevc:0\r\n"))
    #expect(sdp.contains("a=x-nv-vqos[0].bitStreamFormat:0\r\n"))
}

@Test
func announceSDPAdvertisesSurroundAndHDRModes() {
    var configuration = StreamConfiguration.default1080p60
    configuration.audioMode = .surround51
    configuration.dynamicRange = .hdr

    let sdp = String(decoding: RTSPAnnounceSDPBuilder().build(for: configuration), as: UTF8.self)

    #expect(sdp.contains("a=x-nv-audio.surround.numChannels:6\r\n"))
    #expect(sdp.contains("a=x-nv-audio.surround.channelMask:63\r\n"))
    #expect(sdp.contains("a=x-nv-audio.surround.enable:1\r\n"))
    #expect(sdp.contains("a=x-nv-video[0].dynamicRangeMode:1\r\n"))
}

#if canImport(Network)
@Test
func networkRTSPTransportRejectsInvalidSessionURL() async throws {
    let transport = NetworkRTSPTransport()

    await #expect(throws: MoonlightError.self) {
        _ = try await transport.transact(
            sessionURL: "not-a-valid-rtsp-url",
            request: RTSPRequestFactory().describe(url: "rtsp://invalid", cSeq: 1),
            encryptionKey: nil
        )
    }
}
#endif
