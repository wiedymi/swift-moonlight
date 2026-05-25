import CoreGraphics
import Foundation
import Testing
@testable import SwiftMoonlight

@Test
func clientCanAddDiscoverAndPairHost() async throws {
    let hostStore = InMemoryHostStore()
    let client = MoonlightClient(
        configuration: .init(
            hostStore: hostStore,
            identityStore: InMemoryIdentityStore(),
            clock: TestClock(),
            logger: TestLogger(),
            metricsSink: RecordingMetricsSink(),
            hostService: nil,
            sessionService: nil,
            pairingService: nil,
            sessionBootstrapService: nil
        )
    )

    let host = try await client.addHost(.init(address: "192.168.1.10", port: 47989))
    let discoveredHosts = try await client.discoverHosts()

    #expect(discoveredHosts.count == 1)
    #expect(discoveredHosts[0].id == host.id)
    #expect(discoveredHosts[0].pairingState == .unpaired)

    let pairingResult = try await client.pair(hostID: host.id, pin: "1234")
    let refreshedHost = try await client.refreshHost(host.id)

    #expect(pairingResult.state == .paired)
    #expect(refreshedHost.pairingState == .paired)
}

@Test
func discoverHostsMergesDiscoveredHostsIntoStore() async throws {
    let hostStore = InMemoryHostStore()
    let discovery = FixtureHostDiscovery(discoveredHosts: [
        DiscoveredHost(name: "Desk PC", endpoint: .init(address: "192.168.1.20", port: 47989))
    ])
    let client = MoonlightClient(
        configuration: .init(
            hostStore: hostStore,
            hostDiscovery: discovery,
            identityStore: InMemoryIdentityStore(),
            clock: TestClock(),
            logger: TestLogger(),
            metricsSink: RecordingMetricsSink(),
            hostService: nil,
            sessionService: nil,
            pairingService: nil,
            sessionBootstrapService: nil
        )
    )

    let discovered = try await client.discoverHosts()
    let stored = try await hostStore.loadHosts()

    #expect(discovered.count == 1)
    #expect(discovered[0].name == "Desk PC")
    #expect(discovered[0].endpoint.address == "192.168.1.20")
    #expect(stored.count == 1)
}

@Test
func discoverHostsDeduplicatesStoredEndpointsAndPreservesPairedHost() async throws {
    let pairedID = HostID(rawValue: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!)
    let staleID = HostID(rawValue: UUID(uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff")!)
    let hostStore = InMemoryHostStore(
        hosts: [
            MoonlightHost(
                id: staleID,
                name: "apollo-host.local",
                endpoint: .init(address: "APOLLO-HOST.local", port: 47989),
                kind: .unknown,
                pairingState: .unpaired,
                capabilities: .default
            ),
            MoonlightHost(
                id: pairedID,
                name: "apollo-host",
                endpoint: .init(address: "apollo-host.local", port: 47989, securePort: 47984),
                kind: .sunshine,
                pairingState: .paired,
                capabilities: .init(supportedVideoCodecs: [.hevc], supportsHDR: true)
            ),
        ]
    )
    let client = MoonlightClient(
        configuration: .init(
            hostStore: hostStore,
            identityStore: InMemoryIdentityStore(),
            clock: TestClock(),
            logger: TestLogger(),
            metricsSink: RecordingMetricsSink(),
            hostService: nil,
            sessionService: nil,
            pairingService: nil,
            sessionBootstrapService: nil
        )
    )

    let discovered = try await client.discoverHosts()
    let stored = try await hostStore.loadHosts()

    #expect(discovered.count == 1)
    #expect(stored.count == 1)
    #expect(discovered[0].id == pairedID)
    #expect(discovered[0].pairingState == .paired)
    #expect(discovered[0].kind == .sunshine)
    #expect(discovered[0].endpoint.securePort == 47984)
    #expect(discovered[0].capabilities.supportsHDR)
}

@Test
func addHostReturnsExistingEndpointInsteadOfCreatingDuplicate() async throws {
    let existingID = HostID(rawValue: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!)
    let hostStore = InMemoryHostStore(
        hosts: [
            MoonlightHost(
                id: existingID,
                name: "Desk PC",
                endpoint: .init(address: "desk.local", port: 47989),
                kind: .sunshine,
                pairingState: .paired,
                capabilities: .default
            )
        ]
    )
    let client = MoonlightClient(
        configuration: .init(
            hostStore: hostStore,
            identityStore: InMemoryIdentityStore(),
            clock: TestClock(),
            logger: TestLogger(),
            metricsSink: RecordingMetricsSink(),
            hostService: nil,
            sessionService: nil,
            pairingService: nil,
            sessionBootstrapService: nil
        )
    )

    let host = try await client.addHost(.init(address: "DESK.local", port: 47989))
    let stored = try await hostStore.loadHosts()

    #expect(host.id == existingID)
    #expect(stored.count == 1)
    #expect(stored[0].id == existingID)
}

@Test
func updateHostEndpointPreservesPairedMetadataAndSecurePort() async throws {
    let hostID = HostID(rawValue: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!)
    let hostStore = InMemoryHostStore(
        hosts: [
            MoonlightHost(
                id: hostID,
                name: "Desk PC",
                endpoint: .init(address: "desk.local", port: 47989, securePort: 47984),
                kind: .apollo,
                pairingState: .paired,
                capabilities: .init(supportedVideoCodecs: [.hevc], supportsHDR: true)
            )
        ]
    )
    let client = MoonlightClient(
        configuration: .init(
            hostStore: hostStore,
            identityStore: InMemoryIdentityStore(),
            clock: TestClock(),
            logger: TestLogger(),
            metricsSink: RecordingMetricsSink(),
            hostService: nil,
            sessionService: nil,
            pairingService: nil,
            sessionBootstrapService: nil
        )
    )

    let updated = try await client.updateHostEndpoint(
        hostID: hostID,
        endpoint: .init(address: "192.168.1.24", port: 47989)
    )
    let stored = try await hostStore.loadHosts()

    #expect(updated.id == hostID)
    #expect(updated.endpoint.address == "192.168.1.24")
    #expect(updated.endpoint.port == 47989)
    #expect(updated.endpoint.securePort == 47984)
    #expect(updated.pairingState == .paired)
    #expect(updated.kind == .apollo)
    #expect(updated.capabilities.supportsHDR)
    #expect(stored == [updated])
}

@Test
func openSessionNegotiatesStreamingSession() async throws {
    let hostID = HostID()
    let hostStore = InMemoryHostStore(
        hosts: [
            MoonlightHost(
                id: hostID,
                name: "Test Host",
                endpoint: .init(address: "192.168.1.10", port: 47989),
                kind: .sunshine,
                pairingState: .paired,
                capabilities: .default
            )
        ]
    )
    let sessionService = FixtureSessionService(
        negotiatedSession: NegotiatedSession(
            hostID: hostID,
            appID: "desktop",
            rtspSessionURL: "rtsp://192.168.1.10:47998",
            videoFormat: .init(codec: .hevc, dimensions: CGSize(width: 1920, height: 1080)),
            audioFormat: .init(sampleRate: 48_000, channelCount: 2),
            isInputOnly: false
        )
    )
    let client = MoonlightClient(
        configuration: .init(
            hostStore: hostStore,
            identityStore: InMemoryIdentityStore(),
            clock: TestClock(),
            logger: TestLogger(),
            metricsSink: RecordingMetricsSink(),
            hostService: nil,
            sessionService: sessionService,
            pairingService: nil,
            sessionBootstrapService: nil
        )
    )
    let host = try await client.discoverHosts()[0]

    let session = try await client.openSession(
        hostID: host.id,
        appID: "desktop",
        configuration: .default1080p60
    )

    try await session.attachRenderer(NullRenderer())
    try await session.attachAudioSink(NullAudioSink())
    try await session.send(.keyboard(.keyDown(.space)))
    let stateBeforeStop = await session.currentState
    let negotiated = await session.negotiatedSession
    await session.stop()
    let finalState = await session.currentState
    let launchedHostIDs = await sessionService.recordedHostIDs()
    let launchedAppIDs = await sessionService.recordedAppIDs()

    #expect(stateBeforeStop == .streaming)
    #expect(negotiated?.rtspSessionURL == "rtsp://192.168.1.10:47998")
    #expect(finalState == .stopped)
    #expect(launchedHostIDs == [host.id])
    #expect(launchedAppIDs == ["desktop"])
}

@Test
func restartSessionStopsCancelsAndPreparesReplacementRuntime() async throws {
    let hostID = HostID()
    let host = MoonlightHost(
        id: hostID,
        name: "Test Host",
        endpoint: .init(address: "192.168.1.10", port: 47989),
        kind: .sunshine,
        pairingState: .paired,
        capabilities: .default
    )
    let hostService = FixtureHostService(
        serverInfoData: try fixtureData(named: "serverinfo_sunshine_paired.xml"),
        appListData: try fixtureData(named: "applist_sunshine.xml")
    )
    let sessionService = FixtureSessionService(
        negotiatedSession: NegotiatedSession(
            hostID: hostID,
            appID: "desktop",
            rtspSessionURL: "rtsp://192.168.1.10:47998",
            videoFormat: .init(codec: .hevc, dimensions: CGSize(width: 1920, height: 1080)),
            audioFormat: .init(sampleRate: 48_000, channelCount: 2),
            isInputOnly: false
        )
    )
    let client = MoonlightClient(
        configuration: .init(
            hostStore: InMemoryHostStore(hosts: [host]),
            identityStore: InMemoryIdentityStore(),
            clock: TestClock(),
            logger: TestLogger(),
            metricsSink: RecordingMetricsSink(),
            hostService: hostService,
            sessionService: sessionService,
            pairingService: nil,
            sessionBootstrapService: nil
        )
    )

    let initialSession = try await client.openSession(
        hostID: hostID,
        appID: "desktop",
        configuration: .default1080p60
    )
    let initialRuntime = try await client.prepareRuntime(for: initialSession, hostID: hostID)
    var restartConfiguration = StreamConfiguration.default1080p60
    restartConfiguration.resolution = CGSize(width: 2560, height: 1440)
    restartConfiguration.bitrateKbps = 35_000
    let restarted = try await client.restartSession(
        hostID: hostID,
        appID: "desktop",
        configuration: restartConfiguration,
        previousRuntime: initialRuntime,
        options: .init(
            stopExistingRuntime: true,
            cancelCurrentAppBeforeRelaunch: true,
            runtimeConfiguration: .init(maxReconnectAttempts: 2, reconnectBackoff: .milliseconds(1))
        )
    )

    let oldState = await initialSession.currentState
    let newState = await restarted.session.currentState
    let launchedHostIDs = await sessionService.recordedHostIDs()
    let launchedAppIDs = await sessionService.recordedAppIDs()
    let launchConfigurations = await sessionService.recordedConfigurations()
    let cancelledHostIDs = await hostService.recordedCancelledHostIDs()
    let runtimeSnapshot = await restarted.preparedRuntime.runtime.snapshot()

    #expect(oldState == .stopped)
    #expect(newState == .streaming)
    #expect(launchedHostIDs == [hostID, hostID])
    #expect(launchedAppIDs == ["desktop", "desktop"])
    #expect(launchConfigurations.map(\.resolution) == [
        CGSize(width: 1920, height: 1080),
        CGSize(width: 2560, height: 1440),
    ])
    #expect(launchConfigurations.last?.bitrateKbps == 35_000)
    #expect(cancelledHostIDs == [hostID])
    #expect(runtimeSnapshot.reconnectAttempts == 0)
}

@Test
func restartSessionValidatesBeforeStoppingExistingRuntimeOrCancellingHostApp() async throws {
    let hostID = HostID()
    let host = MoonlightHost(
        id: hostID,
        name: "Test Host",
        endpoint: .init(address: "192.168.1.10", port: 47989),
        kind: .sunshine,
        pairingState: .paired,
        capabilities: .default
    )
    let hostService = FixtureHostService(
        serverInfoData: try fixtureData(named: "serverinfo_sunshine_paired.xml"),
        appListData: try fixtureData(named: "applist_sunshine.xml")
    )
    let sessionService = FixtureSessionService(
        negotiatedSession: NegotiatedSession(
            hostID: hostID,
            appID: "desktop",
            rtspSessionURL: "rtsp://192.168.1.10:47998",
            videoFormat: .init(codec: .hevc, dimensions: CGSize(width: 1920, height: 1080)),
            audioFormat: .init(sampleRate: 48_000, channelCount: 2),
            isInputOnly: false
        )
    )
    let client = MoonlightClient(
        configuration: .init(
            hostStore: InMemoryHostStore(hosts: [host]),
            identityStore: InMemoryIdentityStore(),
            clock: TestClock(),
            logger: TestLogger(),
            metricsSink: RecordingMetricsSink(),
            hostService: hostService,
            sessionService: sessionService,
            pairingService: nil,
            sessionBootstrapService: nil
        )
    )

    let initialSession = try await client.openSession(
        hostID: hostID,
        appID: "desktop",
        configuration: .default1080p60
    )
    let initialRuntime = try await client.prepareRuntime(for: initialSession, hostID: hostID)
    var invalidConfiguration = StreamConfiguration.default1080p60
    invalidConfiguration.videoCodecPreference = []

    do {
        _ = try await client.restartSession(
            hostID: hostID,
            appID: "desktop",
            configuration: invalidConfiguration,
            previousRuntime: initialRuntime
        )
        Issue.record("Expected restart configuration validation to fail")
    } catch let error as MoonlightError {
        #expect(error.code == .capabilityMismatch)
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }

    let oldState = await initialSession.currentState
    let launchedHostIDs = await sessionService.recordedHostIDs()
    let cancelledHostIDs = await hostService.recordedCancelledHostIDs()

    #expect(oldState == .streaming)
    #expect(launchedHostIDs == [hostID])
    #expect(cancelledHostIDs.isEmpty)
}

@Test
func openSessionValidatesStreamConfigurationBeforeHostLookup() async throws {
    let client = MoonlightClient(
        configuration: .init(
            hostStore: InMemoryHostStore(),
            identityStore: InMemoryIdentityStore(),
            clock: TestClock(),
            logger: TestLogger(),
            metricsSink: RecordingMetricsSink(),
            hostService: nil,
            sessionService: nil,
            pairingService: nil,
            sessionBootstrapService: nil
        )
    )
    var configuration = StreamConfiguration.default1080p60
    configuration.videoCodecPreference = []

    do {
        _ = try await client.openSession(
            hostID: HostID(),
            appID: "desktop",
            configuration: configuration
        )
        Issue.record("Expected stream configuration validation to fail")
    } catch let error as MoonlightError {
        #expect(error.code == .capabilityMismatch)
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

@Test
func openSessionValidatesStreamConfigurationAgainstRefreshedHostCapabilities() async throws {
    let hostID = HostID()
    let host = MoonlightHost(
        id: hostID,
        name: "H264 Host",
        endpoint: .init(address: "192.168.1.10", port: 47989),
        kind: .sunshine,
        pairingState: .paired,
        capabilities: .init(supportedVideoCodecs: [.h264])
    )
    let sessionService = FixtureSessionService(
        negotiatedSession: NegotiatedSession(
            hostID: hostID,
            appID: "desktop",
            rtspSessionURL: "rtsp://192.168.1.10:47998",
            videoFormat: .init(codec: .h264, dimensions: CGSize(width: 1920, height: 1080)),
            audioFormat: .init(sampleRate: 48_000, channelCount: 2),
            isInputOnly: false
        )
    )
    let client = MoonlightClient(
        configuration: .init(
            hostStore: InMemoryHostStore(hosts: [host]),
            identityStore: InMemoryIdentityStore(),
            clock: TestClock(),
            logger: TestLogger(),
            metricsSink: RecordingMetricsSink(),
            hostService: nil,
            sessionService: sessionService,
            pairingService: nil,
            sessionBootstrapService: nil
        )
    )
    var configuration = StreamConfiguration.default1080p60
    configuration.videoCodecPreference = [.hevc]

    do {
        _ = try await client.openSession(
            hostID: hostID,
            appID: "desktop",
            configuration: configuration
        )
        Issue.record("Expected host capability validation to fail")
    } catch let error as MoonlightError {
        #expect(error.code == .capabilityMismatch)
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }

    let launchedHostIDs = await sessionService.recordedHostIDs()
    #expect(launchedHostIDs.isEmpty)
}

@Test
func openSessionUsesBootstrapServiceAndCarriesEstablishedChannels() async throws {
    let hostID = HostID()
    let host = MoonlightHost(
        id: hostID,
        name: "Test Host",
        endpoint: .init(address: "192.168.1.10", port: 47989),
        kind: .sunshine,
        pairingState: .paired,
        capabilities: .default
    )

    let remoteInputKey = Data(repeating: 0xAB, count: 16)
    let launchService = FixtureSessionService(
        negotiatedSession: NegotiatedSession(
            hostID: hostID,
            appID: "desktop",
            rtspSessionURL: "rtsp://192.168.1.10:47998",
            videoFormat: .init(codec: .hevc, dimensions: CGSize(width: 1920, height: 1080)),
            audioFormat: .init(sampleRate: 48_000, channelCount: 2),
            remoteInputSecrets: .init(key: remoteInputKey, keyID: 42),
            isInputOnly: false
        )
    )
    let rtspTransport = FixtureRTSPTransport(responses: [
        RTSPResponse(statusCode: 200, statusText: "OK"),
        RTSPResponse(statusCode: 200, statusText: "OK"),
        RTSPResponse(statusCode: 200, statusText: "OK", headers: [
            .init(name: "Session", value: "DEADBEEFCAFE;timeout=90"),
            .init(name: "Transport", value: "unicast;server_port=48000-48001"),
            .init(name: "X-SS-Ping-Payload", value: "audpingpayload01"),
        ]),
        RTSPResponse(statusCode: 200, statusText: "OK", headers: [
            .init(name: "Transport", value: "unicast;server_port=47998-47999"),
            .init(name: "X-SS-Ping-Payload", value: "vidpingpayload01"),
        ]),
        RTSPResponse(statusCode: 200, statusText: "OK", headers: [
            .init(name: "Transport", value: "unicast;server_port=47999-48000"),
            .init(name: "X-SS-Connect-Data", value: "0x1234"),
        ]),
        RTSPResponse(statusCode: 200, statusText: "OK"),
        RTSPResponse(statusCode: 200, statusText: "OK"),
    ])
    let channelTransport = RecordingChannelTransport()
    let bootstrap = SessionBootstrap(
        launchService: launchService,
        rtspService: RTSPNegotiationService(transport: rtspTransport),
        channelService: ChannelEstablishmentService(transport: channelTransport)
    )

    let client = MoonlightClient(
        configuration: .init(
            hostStore: InMemoryHostStore(hosts: [host]),
            identityStore: InMemoryIdentityStore(),
            clock: TestClock(),
            logger: TestLogger(),
            metricsSink: RecordingMetricsSink(),
            hostService: nil,
            sessionService: nil,
            pairingService: nil,
            sessionBootstrapService: bootstrap
        )
    )

    let session = try await client.openSession(
        hostID: host.id,
        appID: "desktop",
        configuration: .default1080p60
    )

    let negotiated = await session.negotiatedSession
    #expect(negotiated?.channels.count == 4)
    #expect(negotiated?.channels.map(\.descriptor.kind) == [.control, .input, .video, .audio])
    let channelRequests = await channelTransport.recordedRequests()
    #expect(channelRequests.map(\.descriptor.kind) == [.control, .input, .video])
    let recordedKeys = await rtspTransport.recordedEncryptionKeys()
    #expect(recordedKeys.count == 7)
    #expect(recordedKeys.allSatisfy { $0 == remoteInputKey })
}

@Test
func openSessionBootstrapInfersVideoFormatFromDescribeSDP() async throws {
    let hostID = HostID()
    let host = MoonlightHost(
        id: hostID,
        name: "Test Host",
        endpoint: .init(address: "192.168.1.10", port: 47989),
        kind: .sunshine,
        pairingState: .paired,
        capabilities: .default
    )

    let launchService = FixtureSessionService(
        negotiatedSession: NegotiatedSession(
            hostID: hostID,
            appID: "desktop",
            rtspSessionURL: "rtsp://192.168.1.10:47998",
            audioFormat: .init(sampleRate: 48_000, channelCount: 2),
            remoteInputSecrets: .init(key: Data(repeating: 0xAB, count: 16), keyID: 42),
            isInputOnly: false
        )
    )
    let rtspTransport = FixtureRTSPTransport(responses: [
        RTSPResponse(statusCode: 200, statusText: "OK"),
        RTSPResponse(
            statusCode: 200,
            statusText: "OK",
            body: Data("""
            a=x-ss-general.encryptionSupported:5\r
            sprop-parameter-sets=AAAAAU\r
            """.utf8)
        ),
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
    let bootstrap = SessionBootstrap(
        launchService: launchService,
        rtspService: RTSPNegotiationService(transport: rtspTransport),
        channelService: ChannelEstablishmentService(transport: RecordingChannelTransport())
    )

    let client = MoonlightClient(
        configuration: .init(
            hostStore: InMemoryHostStore(hosts: [host]),
            identityStore: InMemoryIdentityStore(),
            clock: TestClock(),
            logger: TestLogger(),
            metricsSink: RecordingMetricsSink(),
            hostService: nil,
            sessionService: nil,
            pairingService: nil,
            sessionBootstrapService: bootstrap
        )
    )

    let session = try await client.openSession(
        hostID: host.id,
        appID: "desktop",
        configuration: .default1080p60
    )

    let negotiated = await session.negotiatedSession
    #expect(negotiated?.videoFormat?.codec == .hevc)
    #expect(negotiated?.videoFormat?.dimensions == .init(width: 1920, height: 1080))
}

@Test
func openSessionBootstrapUsesRequestedCodecInsteadOfDescribeCapabilityHint() async throws {
    let hostID = HostID()
    let host = MoonlightHost(
        id: hostID,
        name: "Test Host",
        endpoint: .init(address: "192.168.1.10", port: 47989),
        kind: .sunshine,
        pairingState: .paired,
        capabilities: .default
    )

    let launchService = FixtureSessionService(
        negotiatedSession: NegotiatedSession(
            hostID: hostID,
            appID: "desktop",
            rtspSessionURL: "rtsp://192.168.1.10:47998",
            audioFormat: .init(sampleRate: 48_000, channelCount: 2),
            remoteInputSecrets: .init(key: Data(repeating: 0xAB, count: 16), keyID: 42),
            isInputOnly: false
        )
    )
    let rtspTransport = FixtureRTSPTransport(responses: [
        RTSPResponse(statusCode: 200, statusText: "OK"),
        RTSPResponse(
            statusCode: 200,
            statusText: "OK",
            body: Data("""
            a=x-ss-general.encryptionSupported:5\r
            sprop-parameter-sets=AAAAAU\r
            """.utf8)
        ),
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
    let bootstrap = SessionBootstrap(
        launchService: launchService,
        rtspService: RTSPNegotiationService(transport: rtspTransport),
        channelService: ChannelEstablishmentService(transport: RecordingChannelTransport())
    )

    let client = MoonlightClient(
        configuration: .init(
            hostStore: InMemoryHostStore(hosts: [host]),
            identityStore: InMemoryIdentityStore(),
            clock: TestClock(),
            logger: TestLogger(),
            metricsSink: RecordingMetricsSink(),
            hostService: nil,
            sessionService: nil,
            pairingService: nil,
            sessionBootstrapService: bootstrap
        )
    )

    var configuration = StreamConfiguration.default1080p60
    configuration.videoCodecPreference = [.h264, .hevc]

    let session = try await client.openSession(
        hostID: host.id,
        appID: "desktop",
        configuration: configuration
    )

    let negotiated = await session.negotiatedSession
    #expect(negotiated?.videoFormat?.codec == .h264)
}

@Test
func refreshHostUsesHostServiceAndParsers() async throws {
    let host = MoonlightHost(
        id: HostID(),
        name: "Local Host",
        endpoint: .init(address: "192.168.1.10", port: 47989),
        kind: .unknown,
        pairingState: .unpaired,
        capabilities: .default
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
            sessionService: nil,
            pairingService: nil,
            sessionBootstrapService: nil
        )
    )

    let refreshed = try await client.refreshHost(host.id)

    #expect(refreshed.kind == .sunshine)
    #expect(refreshed.pairingState == .paired)
}

@Test
func refreshHostDoesNotDowngradeStoredPairedStateFromHttpPairStatusZero() async throws {
    let host = MoonlightHost(
        id: HostID(),
        name: "Local Host",
        endpoint: .init(address: "192.168.1.10", port: 47989),
        kind: .sunshine,
        pairingState: .paired,
        capabilities: .default
    )
    let client = MoonlightClient(
        configuration: .init(
            hostStore: InMemoryHostStore(hosts: [host]),
            identityStore: InMemoryIdentityStore(),
            clock: TestClock(),
            logger: TestLogger(),
            metricsSink: RecordingMetricsSink(),
            hostService: FixtureHostService(
                serverInfoData: Data("""
                <?xml version="1.0" encoding="utf-8"?>
                <root status_code="200"><hostname>apollo-host</hostname><appversion>7.1.431.-1</appversion><GfeVersion>3.23.0.74</GfeVersion><uniqueid>11111111-2222-3333-4444-555555555555</uniqueid><HttpsPort>47984</HttpsPort><ExternalPort>47989</ExternalPort><MaxLumaPixelsHEVC>1869449984</MaxLumaPixelsHEVC><mac>00:00:00:00:00:00</mac><Permission>0</Permission><LocalIP>192.0.2.28</LocalIP><ServerCodecModeSupport>1835777</ServerCodecModeSupport><PairStatus>0</PairStatus><currentgame>0</currentgame><currentgameuuid/><state>SUNSHINE_SERVER_FREE</state></root>
                """.utf8),
                appListData: try fixtureData(named: "applist_sunshine.xml")
            ),
            sessionService: nil,
            pairingService: nil,
            sessionBootstrapService: nil
        )
    )

    let refreshed = try await client.refreshHost(host.id)

    #expect(refreshed.kind == .apollo)
    #expect(refreshed.pairingState == .paired)
}

@Test
func fetchAppsUsesHostServiceAndReturnsParsedApps() async throws {
    let host = MoonlightHost(
        id: HostID(),
        name: "Local Host",
        endpoint: .init(address: "192.168.1.10", port: 47989),
        kind: .unknown,
        pairingState: .paired,
        capabilities: .default
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
            sessionService: nil,
            pairingService: nil,
            sessionBootstrapService: nil
        )
    )

    let apps = try await client.fetchApps(hostID: host.id)

    #expect(apps.count == 2)
    #expect(apps[0].id == "desktop")
    #expect(apps[1].id == "steam")
}

@Test
func refreshHostDetectsApolloKindFromServerInfo() async throws {
    let host = MoonlightHost(
        id: HostID(),
        name: "Apollo Host",
        endpoint: .init(address: "192.168.1.11", port: 47989),
        kind: .unknown,
        pairingState: .unpaired,
        capabilities: .default
    )
    let client = MoonlightClient(
        configuration: .init(
            hostStore: InMemoryHostStore(hosts: [host]),
            identityStore: InMemoryIdentityStore(),
            clock: TestClock(),
            logger: TestLogger(),
            metricsSink: RecordingMetricsSink(),
            hostService: FixtureHostService(
                serverInfoData: try fixtureData(named: "serverinfo_apollo_paired.xml"),
                appListData: try fixtureData(named: "applist_sunshine.xml")
            ),
            sessionService: nil,
            pairingService: nil,
            sessionBootstrapService: nil
        )
    )

    let refreshed = try await client.refreshHost(host.id)

    #expect(refreshed.kind == .apollo)
    #expect(refreshed.pairingState == .paired)
}

@Test
func pairUsesConfiguredPairingService() async throws {
    let host = MoonlightHost(
        id: HostID(),
        name: "Local Host",
        endpoint: .init(address: "192.168.1.10", port: 47989),
        kind: .unknown,
        pairingState: .unpaired,
        capabilities: .default
    )
    let pairingService = FixturePairingClientService(
        result: PairingResult(hostID: host.id, state: .paired)
    )
    let identity = ClientIdentity(
        identifier: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        displayName: "Tester"
    )
    let client = MoonlightClient(
        configuration: .init(
            hostStore: InMemoryHostStore(hosts: [host]),
            identityStore: InMemoryIdentityStore(identity: identity),
            clock: TestClock(),
            logger: TestLogger(),
            metricsSink: RecordingMetricsSink(),
            hostService: nil,
            sessionService: nil,
            pairingService: pairingService,
            sessionBootstrapService: nil
        )
    )

    let result = try await client.pair(hostID: host.id, pin: "1234")
    let refreshed = try await client.refreshHost(host.id)
    let requests = await pairingService.recordedRequests()

    #expect(result.state == .paired)
    #expect(refreshed.pairingState == .paired)
    #expect(requests.count == 1)
    #expect(requests[0].hostID == host.id)
    #expect(requests[0].auth == .pin("1234"))
    #expect(requests[0].identityID == identity.identifier)
}

@Test
func unpairUsesConfiguredPairingService() async throws {
    let host = MoonlightHost(
        id: HostID(),
        name: "Local Host",
        endpoint: .init(address: "192.168.1.10", port: 47989),
        kind: .sunshine,
        pairingState: .paired,
        capabilities: .default
    )
    let pairingService = FixturePairingClientService(
        result: PairingResult(hostID: host.id, state: .paired)
    )
    let identity = ClientIdentity(
        identifier: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        displayName: "Tester"
    )
    let client = MoonlightClient(
        configuration: .init(
            hostStore: InMemoryHostStore(hosts: [host]),
            identityStore: InMemoryIdentityStore(identity: identity),
            clock: TestClock(),
            logger: TestLogger(),
            metricsSink: RecordingMetricsSink(),
            hostService: nil,
            sessionService: nil,
            pairingService: pairingService,
            sessionBootstrapService: nil
        )
    )

    try await client.unpair(hostID: host.id)
    let refreshed = try await client.refreshHost(host.id)
    let requests = await pairingService.recordedUnpairRequests()

    #expect(refreshed.pairingState == .unpaired)
    #expect(requests.count == 1)
    #expect(requests[0].hostID == host.id)
    #expect(requests[0].identityID == identity.identifier)
}

@Test
func openSessionForwardsMetricsToConfiguredSink() async throws {
    let hostID = HostID()
    let host = MoonlightHost(
        id: hostID,
        name: "Metrics Host",
        endpoint: .init(address: "192.168.1.10", port: 47989),
        kind: .sunshine,
        pairingState: .paired,
        capabilities: .default
    )
    let metricsSink = RecordingMetricsSink()
    let clock = AdvancingTestClock(dates: [
        Date(timeIntervalSince1970: 10),
        Date(timeIntervalSince1970: 10.250),
        Date(timeIntervalSince1970: 100),
        Date(timeIntervalSince1970: 100.010),
        Date(timeIntervalSince1970: 101),
        Date(timeIntervalSince1970: 101.007)
    ])
    let client = MoonlightClient(
        configuration: .init(
            hostStore: InMemoryHostStore(hosts: [host]),
            identityStore: InMemoryIdentityStore(),
            clock: clock,
            logger: TestLogger(),
            metricsSink: metricsSink,
            hostService: nil,
            sessionService: FixtureSessionService(
                negotiatedSession: NegotiatedSession(
                    hostID: hostID,
                    appID: "desktop",
                    rtspSessionURL: "rtsp://192.168.1.10:47998"
                )
            ),
            pairingService: nil,
            sessionBootstrapService: nil
        )
    )

    let session = try await client.openSession(
        hostID: host.id,
        appID: "desktop",
        configuration: .default1080p60
    )
    try await session.attachVideoDecoder(RecordingVideoDecoder(decodeOutputs: [[
        DecodedVideoFrame(timestamp: 1, dimensions: CGSize(width: 640, height: 360), bytes: Data([0xFF]))
    ]]))
    try await session.attachRenderer(NullRenderer())
    try await session.attachAudioDecoder(RecordingAudioDecoder(outputs: [
        PCMBuffer(sampleRate: 48_000, channelCount: 2, frameCount: 480, bytesPerFrame: 4, data: Data([0x00, 0x01]))
    ]))
    try await session.attachAudioSink(NullAudioSink())
    try await session.configureVideo(format: .init(codec: .hevc, dimensions: CGSize(width: 640, height: 360)))
    try await session.configureAudio(format: .init(sampleRate: 48_000, channelCount: 2))
    try await session.send(.keyboard(.keyDown(.space)))
    try await session.receive(.init(timestamp: 1, isKeyFrame: true, codec: .hevc, payload: Data([0x01])))
    try await session.receive(.init(timestamp: 2, payload: Data([0x02])))
    let snapshots = await waitForRecordedSnapshots(in: metricsSink) { snapshots in
        let hasOpenDuration = snapshots.contains { $0.sessionOpenDurationMs == 250 }
        let hasInputCount = snapshots.contains { $0.inputEventsSent == 1 }
        let hasVideoCounts = snapshots.contains { snapshot in
            snapshot.decodedVideoFrames == 1 && snapshot.renderedVideoFrames == 1
        }
        let hasAudioCounts = snapshots.contains { snapshot in
            snapshot.decodedAudioBuffers == 1 && snapshot.playedAudioBuffers == 1
        }
        let hasVideoLatency = snapshots.contains { snapshot in
            approximatelyEqual(snapshot.averageVideoDecodeLatencyMs, 10) &&
            approximatelyEqual(snapshot.maxVideoDecodeLatencyMs, 10)
        }
        let hasAudioLatency = snapshots.contains { snapshot in
            approximatelyEqual(snapshot.averageAudioDecodeLatencyMs, 7) &&
            approximatelyEqual(snapshot.maxAudioDecodeLatencyMs, 7)
        }
        return hasOpenDuration && hasInputCount && hasVideoCounts && hasAudioCounts && hasVideoLatency && hasAudioLatency
    }
    await session.stop()
    let hasOpenDuration = snapshots.contains { $0.sessionOpenDurationMs == 250 }
    let hasInputCount = snapshots.contains { $0.inputEventsSent == 1 }
    let hasVideoCounts = snapshots.contains { snapshot in
        snapshot.decodedVideoFrames == 1 && snapshot.renderedVideoFrames == 1
    }
    let hasAudioCounts = snapshots.contains { snapshot in
        snapshot.decodedAudioBuffers == 1 && snapshot.playedAudioBuffers == 1
    }
    let hasVideoLatency = snapshots.contains { snapshot in
        approximatelyEqual(snapshot.averageVideoDecodeLatencyMs, 10) &&
        approximatelyEqual(snapshot.maxVideoDecodeLatencyMs, 10)
    }
    let hasAudioLatency = snapshots.contains { snapshot in
        approximatelyEqual(snapshot.averageAudioDecodeLatencyMs, 7) &&
        approximatelyEqual(snapshot.maxAudioDecodeLatencyMs, 7)
    }

    #expect(hasOpenDuration)
    #expect(hasInputCount)
    #expect(hasVideoCounts)
    #expect(hasAudioCounts)
    #expect(hasVideoLatency)
    #expect(hasAudioLatency)
}

private func waitForRecordedSnapshots(
    in sink: RecordingMetricsSink,
    timeout: Duration = .milliseconds(250),
    until condition: @Sendable ([SessionMetricsSnapshot]) -> Bool
) async -> [SessionMetricsSnapshot] {
    let deadline = ContinuousClock.now + timeout
    var latest = await sink.recordedSnapshots()

    while ContinuousClock.now < deadline {
        latest = await sink.recordedSnapshots()
        if condition(latest) {
            return latest
        }
        try? await Task.sleep(for: .milliseconds(5))
    }

    return latest
}

private func approximatelyEqual(_ lhs: Double?, _ rhs: Double, tolerance: Double = 0.001) -> Bool {
    guard let lhs else {
        return false
    }
    return abs(lhs - rhs) <= tolerance
}
