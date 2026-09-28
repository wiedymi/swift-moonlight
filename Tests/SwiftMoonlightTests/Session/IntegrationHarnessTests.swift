import CoreGraphics
import Foundation
import Testing
@testable import SwiftMoonlight

@Test
func integrationHarnessRunsHeadlessSmokeFlow() async throws {
    let host = MoonlightHost(
        id: HostID(),
        name: "Harness Host",
        endpoint: .init(address: "192.168.1.10", port: 47989),
        kind: .unknown,
        pairingState: .unpaired,
        capabilities: .default
    )
    let negotiated = NegotiatedSession(
        hostID: host.id,
        appID: "desktop",
        rtspSessionURL: "rtsp://192.168.1.10:47998",
        videoFormat: .init(codec: .hevc, dimensions: CGSize(width: 1280, height: 720)),
        audioFormat: .init(sampleRate: 48_000, channelCount: 2)
    )
    let client = MoonlightClient(
        configuration: .init(
            hostStore: InMemoryHostStore(hosts: [host]),
            identityStore: InMemoryIdentityStore(),
            clock: TestClock(),
            logger: TestLogger(),
            metricsSink: RecordingMetricsSink(),
            hostService: FixtureHostService(
                serverInfoData: try fixtureData(named: "serverinfo_sunshine_paired.xml"),
                appListData: try fixtureData(named: "applist_sunshine.xml")
            ),
            sessionService: FixtureSessionService(negotiatedSession: negotiated),
            pairingService: FixturePairingClientService(
                result: .init(hostID: host.id, state: .paired)
            )
        )
    )
    let harness = IntegrationHarness(
        client: client,
        configuration: .init(
            endpoint: host.endpoint,
            pinProvider: { "1234" },
            appID: "desktop",
            streamConfiguration: .default1080p60,
            observationWindow: .milliseconds(10)
        )
    )

    let report = try await harness.runSmokeTest()

    #expect(report.paired)
    #expect(report.appsFetched)
    #expect(report.launchAccepted)
    #expect(!report.controlConnected)
    #expect(!report.inputConnected)
    #expect(report.inputPacketsSent == 0)
    #expect(!report.inputProbeSucceeded)
    #expect(report.videoPacketsObserved == 0)
    #expect(report.audioPacketsObserved == 0)
    #expect(report.audioExpected)
    #expect(!report.unexpectedDisconnect)
    #expect(!report.passed)
    #expect(report.failures() == [
        "control channel was not established",
        "input channel was not established",
        "video channel observed no packets",
        "audio channel observed no packets",
    ])
}

@Test
func integrationHarnessCancelsCurrentAppBeforeLaunchWhenConfigured() async throws {
    let host = MoonlightHost(
        id: HostID(),
        name: "Harness Host",
        endpoint: .init(address: "192.168.1.10", port: 47989),
        kind: .sunshine,
        pairingState: .paired,
        capabilities: .default
    )
    let negotiated = NegotiatedSession(
        hostID: host.id,
        appID: "desktop",
        rtspSessionURL: "rtsp://192.168.1.10:47998",
        videoFormat: .init(codec: .hevc, dimensions: CGSize(width: 1280, height: 720)),
        audioFormat: nil
    )
    let hostService = FixtureHostService(
        serverInfoData: try fixtureData(named: "serverinfo_sunshine_paired.xml"),
        appListData: try fixtureData(named: "applist_sunshine.xml")
    )
    let sessionService = FixtureSessionService(negotiatedSession: negotiated)
    let client = MoonlightClient(
        configuration: .init(
            hostStore: InMemoryHostStore(hosts: [host]),
            identityStore: InMemoryIdentityStore(),
            clock: TestClock(),
            logger: TestLogger(),
            metricsSink: RecordingMetricsSink(),
            hostService: hostService,
            sessionService: sessionService
        )
    )
    let harness = IntegrationHarness(
        client: client,
        configuration: .init(
            endpoint: host.endpoint,
            pinProvider: { "1234" },
            appID: "desktop",
            streamConfiguration: .default1080p60,
            observationWindow: .milliseconds(10),
            cancelCurrentAppBeforeLaunch: true
        )
    )

    let report = try await harness.runSmokeTest()

    #expect(report.preLaunchCancelAttempted)
    #expect(await hostService.recordedCancelledHostIDs() == [host.id])
    #expect(await sessionService.recordedHostIDs() == [host.id])
}

@Test
func integrationHarnessAdoptsOverrideEndpointForSinglePairedStoredHost() async throws {
    let pairedID = HostID()
    let pairedHost = MoonlightHost(
        id: pairedID,
        name: "apollo-host",
        endpoint: .init(address: "apollo-host.local", port: 47989, securePort: 47984),
        kind: .apollo,
        pairingState: .paired,
        capabilities: .default
    )
    let unpairedDuplicate = MoonlightHost(
        id: HostID(),
        name: "192.168.1.24",
        endpoint: .init(address: "192.168.1.24", port: 47989, securePort: 47984),
        kind: .sunshine,
        pairingState: .unpaired,
        capabilities: .default
    )
    let hostStore = InMemoryHostStore(hosts: [pairedHost, unpairedDuplicate])
    let pairingService = FixturePairingClientService(
        result: .init(hostID: pairedID, state: .paired)
    )
    let sessionService = FixtureSessionService(
        negotiatedSession: NegotiatedSession(
            hostID: pairedID,
            appID: "desktop",
            rtspSessionURL: "rtsp://192.168.1.24:47998",
            videoFormat: .init(codec: .hevc, dimensions: CGSize(width: 1280, height: 720)),
            audioFormat: .init(sampleRate: 48_000, channelCount: 2)
        )
    )
    let client = MoonlightClient(
        configuration: .init(
            hostStore: hostStore,
            identityStore: InMemoryIdentityStore(),
            clock: TestClock(),
            logger: TestLogger(),
            metricsSink: RecordingMetricsSink(),
            hostService: FixtureHostService(
                serverInfoData: try fixtureData(named: "serverinfo_sunshine_paired.xml"),
                appListData: Data("""
                <?xml version="1.0" encoding="UTF-8"?>
                <root status_code="200">
                  <App>
                    <ID>881448767</ID>
                    <AppTitle>Desktop</AppTitle>
                  </App>
                </root>
                """.utf8)
            ),
            sessionService: sessionService,
            pairingService: pairingService
        )
    )
    var restartConfiguration = StreamConfiguration.default1080p60
    restartConfiguration.resolution = CGSize(width: 1600, height: 900)
    let harness = IntegrationHarness(
        client: client,
        configuration: .init(
            endpoint: .init(address: "192.168.1.24", port: 47989),
            pinProvider: { "1234" },
            appID: "desktop",
            streamConfiguration: .default1080p60,
            observationWindow: .milliseconds(10),
            restartStreamConfiguration: restartConfiguration,
            restartCount: 2
        )
    )

    let report = try await harness.runSmokeTest()
    let storedHosts = try await hostStore.loadHosts()

    #expect(report.paired)
    #expect(report.restartAttempted)
    #expect(report.restartLaunchAccepted)
    #expect(report.restartCountRequested == 2)
    #expect(report.restartObservations.map(\.index) == [1, 2])
    #expect(report.restartObservations.map(\.launchAccepted) == [true, true])
    #expect(await pairingService.recordedRequests().isEmpty)
    #expect(await sessionService.recordedHostIDs() == [pairedID, pairedID, pairedID])
    #expect(await sessionService.recordedAppIDs() == ["881448767", "881448767", "881448767"])
    #expect(await sessionService.recordedConfigurations().map(\.resolution) == [
        CGSize(width: 1920, height: 1080),
        CGSize(width: 1600, height: 900),
        CGSize(width: 1600, height: 900),
    ])
    #expect(storedHosts.count == 1)
    #expect(storedHosts[0].id == pairedID)
    #expect(storedHosts[0].pairingState == .paired)
    #expect(storedHosts[0].endpoint.address == "192.168.1.24")
}

@Test
func integrationHarnessConfigurationParsesEnvironmentHostVariants() async throws {
    let bareHost = try IntegrationHarnessConfiguration.fromEnvironment([
        "SWIFT_MOONLIGHT_TEST_HOST": "192.168.1.10"
    ])
    let hostWithPort = try IntegrationHarnessConfiguration.fromEnvironment([
        "SWIFT_MOONLIGHT_TEST_HOST": "192.168.1.10:48010",
        "SWIFT_MOONLIGHT_TEST_PIN": "9876",
        "SWIFT_MOONLIGHT_TEST_APP_ID": "steam"
    ])
    let urlHost = try IntegrationHarnessConfiguration.fromEnvironment([
        "SWIFT_MOONLIGHT_TEST_HOST": "http://192.168.1.20:47990"
    ])
    let otpHost = try IntegrationHarnessConfiguration.fromEnvironment([
        "SWIFT_MOONLIGHT_TEST_HOST": "192.168.1.30",
        "SWIFT_MOONLIGHT_TEST_PIN": "2468",
        "SWIFT_MOONLIGHT_TEST_PASSPHRASE": "apollo-passphrase"
    ])
    let restartHost = try IntegrationHarnessConfiguration.fromEnvironment([
        "SWIFT_MOONLIGHT_TEST_HOST": "192.168.1.40",
        "SWIFT_MOONLIGHT_TEST_RESOLUTION": "1280x720",
        "SWIFT_MOONLIGHT_TEST_FPS": "30",
        "SWIFT_MOONLIGHT_TEST_BITRATE_KBPS": "8000",
        "SWIFT_MOONLIGHT_TEST_DYNAMIC_RANGE": "sdr",
        "SWIFT_MOONLIGHT_TEST_CODECS": "h264,hevc",
        "SWIFT_MOONLIGHT_TEST_RESTART_RESOLUTION": "1600x900",
        "SWIFT_MOONLIGHT_TEST_RESTART_COUNT": "3",
        "SWIFT_MOONLIGHT_TEST_INPUT_PROBE_REPEAT_COUNT": "8",
        "SWIFT_MOONLIGHT_TEST_MAX_INPUT_LATENCY_MS": "25.5",
        "SWIFT_MOONLIGHT_TEST_MAX_MISSING_VIDEO_PACKETS": "7",
        "SWIFT_MOONLIGHT_TEST_MAX_VIDEO_DISCONTINUITIES": "2",
        "SWIFT_MOONLIGHT_TEST_VIDEO_PACKET_TRACE_LIMIT": "12",
        "SWIFT_MOONLIGHT_TEST_OBSERVATION_SECONDS": "2.5",
        "SWIFT_MOONLIGHT_TEST_CANCEL_BEFORE_LAUNCH": "1",
    ])

    #expect(bareHost.endpoint == .init(address: "192.168.1.10", port: 47989))
    #expect(hostWithPort.endpoint == .init(address: "192.168.1.10", port: 48010))
    #expect(urlHost.endpoint == .init(address: "192.168.1.20", port: 47990))

    let hostWithPortAuth = try await hostWithPort.pairingAuthProvider()
    let urlHostAuth = try await urlHost.pairingAuthProvider()
    let otpAuth = try await otpHost.pairingAuthProvider()
    #expect(hostWithPortAuth == .pin("9876"))
    #expect(urlHostAuth == .pin("1234"))
    #expect(otpAuth == .otp(pin: "2468", passphrase: "apollo-passphrase"))
    #expect(hostWithPort.appID == "steam")
    #expect(urlHost.appID == "desktop")
    #expect(bareHost.streamConfiguration.requestContinuousAudio)
    #expect(!bareHost.requireAudioPackets)
    #expect(bareHost.inputProbeMode == .noop)
    #expect(restartHost.streamConfiguration.resolution == CGSize(width: 1280, height: 720))
    #expect(restartHost.streamConfiguration.frameRate == 30)
    #expect(restartHost.streamConfiguration.bitrateKbps == 8000)
    #expect(restartHost.streamConfiguration.dynamicRange == .sdr)
    #expect(restartHost.streamConfiguration.videoCodecPreference == [.h264, .hevc])
    #expect(restartHost.restartStreamConfiguration?.resolution == CGSize(width: 1600, height: 900))
    #expect(restartHost.restartStreamConfiguration?.frameRate == 30)
    #expect(restartHost.restartStreamConfiguration?.bitrateKbps == 8000)
    #expect(restartHost.restartStreamConfiguration?.videoCodecPreference == [.h264, .hevc])
    #expect(restartHost.restartCount == 3)
    #expect(restartHost.inputProbeRepeatCount == 8)
    #expect(restartHost.maxInputLatencyMs == 25.5)
    #expect(restartHost.maxMissingVideoPackets == 7)
    #expect(restartHost.maxVideoDiscontinuities == 2)
    #expect(restartHost.runtimeConfiguration.videoPacketTraceLimit == 12)
    #expect(restartHost.observationWindow == .milliseconds(2500))
    #expect(restartHost.cancelCurrentAppBeforeLaunch)
}

@Test
func integrationHarnessConfigurationAllowsDisablingContinuousAudio() throws {
    let configuration = try IntegrationHarnessConfiguration.fromEnvironment([
        "SWIFT_MOONLIGHT_TEST_HOST": "192.168.1.10",
        "SWIFT_MOONLIGHT_TEST_CONTINUOUS_AUDIO": "0",
    ])

    #expect(!configuration.streamConfiguration.requestContinuousAudio)
}

@Test
func integrationHarnessConfigurationAllowsRequiringAudioPackets() throws {
    let configuration = try IntegrationHarnessConfiguration.fromEnvironment([
        "SWIFT_MOONLIGHT_TEST_HOST": "192.168.1.10",
        "SWIFT_MOONLIGHT_TEST_REQUIRE_AUDIO": "1",
    ])

    #expect(configuration.requireAudioPackets)
}

@Test
func integrationHarnessConfigurationRejectsInvalidRestartCount() {
    #expect(throws: MoonlightError.self) {
        _ = try IntegrationHarnessConfiguration.fromEnvironment([
            "SWIFT_MOONLIGHT_TEST_HOST": "192.168.1.10",
            "SWIFT_MOONLIGHT_TEST_RESTART_COUNT": "0",
        ])
    }
}

@Test
func integrationHarnessConfigurationRejectsInvalidInputSoakValues() {
    #expect(throws: MoonlightError.self) {
        _ = try IntegrationHarnessConfiguration.fromEnvironment([
            "SWIFT_MOONLIGHT_TEST_HOST": "192.168.1.10",
            "SWIFT_MOONLIGHT_TEST_INPUT_PROBE_REPEAT_COUNT": "0",
        ])
    }

    #expect(throws: MoonlightError.self) {
        _ = try IntegrationHarnessConfiguration.fromEnvironment([
            "SWIFT_MOONLIGHT_TEST_HOST": "192.168.1.10",
            "SWIFT_MOONLIGHT_TEST_MAX_INPUT_LATENCY_MS": "-1",
        ])
    }

    #expect(throws: MoonlightError.self) {
        _ = try IntegrationHarnessConfiguration.fromEnvironment([
            "SWIFT_MOONLIGHT_TEST_HOST": "192.168.1.10",
            "SWIFT_MOONLIGHT_TEST_MAX_MISSING_VIDEO_PACKETS": "-1",
        ])
    }

    #expect(throws: MoonlightError.self) {
        _ = try IntegrationHarnessConfiguration.fromEnvironment([
            "SWIFT_MOONLIGHT_TEST_HOST": "192.168.1.10",
            "SWIFT_MOONLIGHT_TEST_MAX_VIDEO_DISCONTINUITIES": "not-a-number",
        ])
    }

    #expect(throws: MoonlightError.self) {
        _ = try IntegrationHarnessConfiguration.fromEnvironment([
            "SWIFT_MOONLIGHT_TEST_HOST": "192.168.1.10",
            "SWIFT_MOONLIGHT_TEST_VIDEO_PACKET_TRACE_LIMIT": "-1",
        ])
    }

    #expect(throws: MoonlightError.self) {
        _ = try IntegrationHarnessConfiguration.fromEnvironment([
            "SWIFT_MOONLIGHT_TEST_HOST": "192.168.1.10",
            "SWIFT_MOONLIGHT_TEST_RESOLUTION": "bad",
        ])
    }

    #expect(throws: MoonlightError.self) {
        _ = try IntegrationHarnessConfiguration.fromEnvironment([
            "SWIFT_MOONLIGHT_TEST_HOST": "192.168.1.10",
            "SWIFT_MOONLIGHT_TEST_FPS": "0",
        ])
    }

    #expect(throws: MoonlightError.self) {
        _ = try IntegrationHarnessConfiguration.fromEnvironment([
            "SWIFT_MOONLIGHT_TEST_HOST": "192.168.1.10",
            "SWIFT_MOONLIGHT_TEST_CODEC": "vp9",
        ])
    }
}

@Test
func integrationHarnessConfigurationParsesInputProbeMode() throws {
    let disabled = try IntegrationHarnessConfiguration.fromEnvironment([
        "SWIFT_MOONLIGHT_TEST_HOST": "192.168.1.10",
        "SWIFT_MOONLIGHT_TEST_INPUT_PROBE": "disabled",
    ])
    let motion = try IntegrationHarnessConfiguration.fromEnvironment([
        "SWIFT_MOONLIGHT_TEST_HOST": "192.168.1.10",
        "SWIFT_MOONLIGHT_TEST_INPUT_PROBE": "motion",
    ])
    let absolute = try IntegrationHarnessConfiguration.fromEnvironment([
        "SWIFT_MOONLIGHT_TEST_HOST": "192.168.1.10",
        "SWIFT_MOONLIGHT_TEST_INPUT_PROBE": "absolute",
    ])
    let fallback = try IntegrationHarnessConfiguration.fromEnvironment([
        "SWIFT_MOONLIGHT_TEST_HOST": "192.168.1.10",
        "SWIFT_MOONLIGHT_TEST_INPUT_PROBE": "unknown",
    ])

    #expect(disabled.inputProbeMode == .disabled)
    #expect(motion.inputProbeMode == .reversibleRelativeMotion)
    #expect(absolute.inputProbeMode == .absolutePointerSweep)
    #expect(fallback.inputProbeMode == .noop)
}

@Test
func smokeTestReportPassesWhenRequiredChannelsAndPacketsArePresent() {
    let report = SmokeTestReport(
        paired: true,
        appsFetched: true,
        preLaunchCancelAttempted: true,
        launchAccepted: true,
        controlConnected: true,
        inputConnected: true,
        controlRoundTripTimeMs: 14,
        controlRoundTripTimeVarianceMs: 4,
        controlPacketLossRatio: 0.015,
        controlPacketLossVarianceRatio: 0.003,
        videoPacketsObserved: 4,
        audioPacketsObserved: 2,
        inputPacketsSent: 1,
        inputProbeSucceeded: true,
        audioExpected: true,
        unexpectedDisconnect: false
    )

    #expect(report.passed)
    #expect(report.failures().isEmpty)
}

@Test
func smokeTestReportFailsWhenConnectedInputProbeFails() {
    let report = SmokeTestReport(
        paired: true,
        appsFetched: true,
        preLaunchCancelAttempted: true,
        launchAccepted: true,
        controlConnected: true,
        inputConnected: true,
        controlRoundTripTimeMs: 14,
        controlRoundTripTimeVarianceMs: 4,
        controlPacketLossRatio: 0.015,
        controlPacketLossVarianceRatio: 0.003,
        videoPacketsObserved: 4,
        audioPacketsObserved: 2,
        inputPacketsSent: 0,
        inputProbeSucceeded: false,
        audioExpected: true,
        unexpectedDisconnect: false
    )

    #expect(!report.passed)
    #expect(report.failures() == ["input probe did not complete"])
}

@Test
func smokeTestReportAllowsDisabledInputProbe() {
    let report = SmokeTestReport(
        paired: true,
        appsFetched: true,
        launchAccepted: true,
        controlConnected: true,
        inputConnected: true,
        videoPacketsObserved: 4,
        audioPacketsObserved: 2,
        inputPacketsSent: 0,
        inputProbeSucceeded: false,
        inputProbeMode: .disabled,
        audioExpected: true,
        unexpectedDisconnect: false
    )

    #expect(report.passed)
    #expect(report.failures().isEmpty)
}

@Test
func smokeTestReportFailsWhenInputLatencyExceedsThreshold() {
    let report = SmokeTestReport(
        paired: true,
        appsFetched: true,
        launchAccepted: true,
        controlConnected: true,
        inputConnected: true,
        videoPacketsObserved: 4,
        audioPacketsObserved: 2,
        maxInputQueueLatencyMs: 12,
        maxInputTransportLatencyMs: 4,
        inputProbeSucceeded: true,
        maxInputLatencyMs: 10,
        audioExpected: true,
        unexpectedDisconnect: false
    )

    #expect(!report.passed)
    #expect(report.failures() == ["input queue latency exceeded 10.0 ms"])
}

@Test
func smokeTestReportFailsWhenVideoQualityCountersExceedThresholds() {
    let report = SmokeTestReport(
        paired: true,
        appsFetched: true,
        launchAccepted: true,
        controlConnected: true,
        inputConnected: true,
        videoPacketsObserved: 4,
        audioPacketsObserved: 2,
        missingVideoPackets: 3,
        videoDiscontinuityEvents: 2,
        inputProbeSucceeded: true,
        maxMissingVideoPackets: 2,
        maxVideoDiscontinuities: 1,
        audioExpected: true,
        unexpectedDisconnect: false
    )

    #expect(!report.passed)
    #expect(report.failures() == [
        "missing video packets exceeded 2: 3",
        "video discontinuities exceeded 1: 2",
    ])
}

@Test
func smokeTestReportFailsWhenRestartVideoQualityCountersExceedThresholds() {
    let report = SmokeTestReport(
        paired: true,
        appsFetched: true,
        launchAccepted: true,
        controlConnected: true,
        inputConnected: true,
        videoPacketsObserved: 4,
        audioPacketsObserved: 2,
        inputProbeSucceeded: true,
        maxMissingVideoPackets: 2,
        maxVideoDiscontinuities: 1,
        audioExpected: true,
        unexpectedDisconnect: false,
        restartAttempted: true,
        restartLaunchAccepted: true,
        restartControlConnected: true,
        restartInputConnected: true,
        restartVideoPacketsObserved: 5,
        restartAudioPacketsObserved: 2,
        restartUnexpectedDisconnect: false,
        restartCountRequested: 1,
        restartObservations: [
            SmokeRestartObservation(
                index: 1,
                launchAccepted: true,
                controlConnected: true,
                inputConnected: true,
                videoPacketsObserved: 5,
                audioPacketsObserved: 2,
                missingVideoPackets: 4,
                videoDiscontinuityEvents: 3
            ),
        ]
    )

    #expect(!report.passed)
    #expect(report.failures() == [
        "restart missing video packets exceeded 2: 4",
        "restart video discontinuities exceeded 1: 3",
    ])
}

@Test
func smokeTestReportRoundTripsThroughJSON() throws {
    let report = SmokeTestReport(
        paired: true,
        appsFetched: true,
        preLaunchCancelAttempted: true,
        launchAccepted: true,
        controlConnected: true,
        inputConnected: true,
        controlRoundTripTimeMs: 14,
        controlRoundTripTimeVarianceMs: 4,
        controlPacketLossRatio: 0.015,
        controlPacketLossVarianceRatio: 0.003,
        videoPacketsObserved: 4,
        audioPacketsObserved: 2,
        missingVideoPackets: 1,
        reorderedVideoPackets: 0,
        videoDiscontinuityEvents: 1,
        videoFrameFECStatusReports: 1,
        decodedVideoFrames: 3,
        renderedVideoFrames: 3,
        inputPacketsSent: 2,
        averageInputQueueLatencyMs: 0.25,
        maxInputQueueLatencyMs: 0.5,
        averageInputTransportLatencyMs: 0.75,
        maxInputTransportLatencyMs: 1.25,
        inputProbeSucceeded: true,
        inputProbeMode: .reversibleRelativeMotion,
        inputProbeRepeatCount: 8,
        maxInputLatencyMs: 25.5,
        maxMissingVideoPackets: 7,
        maxVideoDiscontinuities: 2,
        videoPacketTrace: [
            VideoPacketTraceEntry(
                observedPacketIndex: 3,
                usedDecryptor: true,
                usedSyntheticSequenceNumber: false,
                encryptedByteCount: 128,
                rawByteCount: 96,
                sequenceNumber: 10,
                packetType: 96,
                timestamp: 90_000,
                streamPacketIndex: 2,
                frameIndex: 5,
                flags: VideoPacketHeader.startOfFrameFlag,
                fecShardIndex: 0,
                dataShardCount: 4,
                fecPercentage: 20,
                fecBlockIndex: 0,
                fecLastBlockIndex: 0,
                isStartOfFrame: true,
                isEndOfFrame: false,
                isParityShard: false
            ),
        ],
        audioExpected: true,
        unexpectedDisconnect: false,
        restartAttempted: true,
        restartLaunchAccepted: true,
        restartControlConnected: true,
        restartInputConnected: true,
        restartVideoPacketsObserved: 5,
        restartAudioPacketsObserved: 2,
        restartDecodedVideoFrames: 4,
        restartRenderedVideoFrames: 4,
        restartUnexpectedDisconnect: false,
        restartCountRequested: 2,
        restartObservations: [
            SmokeRestartObservation(
                index: 1,
                launchAccepted: true,
                controlConnected: true,
                inputConnected: true,
                controlRoundTripTimeMs: 13,
                controlPacketLossRatio: 0.01,
                videoPacketsObserved: 5,
                audioPacketsObserved: 2,
                videoFrameFECStatusReports: 1,
                decodedVideoFrames: 4,
                renderedVideoFrames: 4
            ),
            SmokeRestartObservation(
                index: 2,
                launchAccepted: true,
                controlConnected: true,
                inputConnected: true,
                controlRoundTripTimeMs: 12,
                controlPacketLossRatio: 0.02,
                videoPacketsObserved: 6,
                audioPacketsObserved: 3,
                videoFrameFECStatusReports: 2,
                decodedVideoFrames: 5,
                renderedVideoFrames: 5
            ),
        ]
    )

    let data = try JSONEncoder().encode(report)
    let decoded = try JSONDecoder().decode(SmokeTestReport.self, from: data)

    #expect(decoded == report)
    #expect(decoded.inputProbeMode == .reversibleRelativeMotion)
    #expect(decoded.preLaunchCancelAttempted)
    #expect(decoded.inputProbeRepeatCount == 8)
    #expect(decoded.maxInputLatencyMs == 25.5)
    #expect(decoded.maxMissingVideoPackets == 7)
    #expect(decoded.maxVideoDiscontinuities == 2)
    #expect(decoded.videoPacketTrace.count == 1)
    #expect(decoded.videoPacketTrace[0].sequenceNumber == 10)
    #expect(decoded.videoPacketTrace[0].usedDecryptor)
    #expect(decoded.controlRoundTripTimeMs == 14)
    #expect(decoded.controlPacketLossRatio == 0.015)
    #expect(decoded.restartObservations[0].controlRoundTripTimeMs == 13)
    #expect(decoded.restartAttempted)
    #expect(decoded.restartObservations.map(\.index) == [1, 2])
}
