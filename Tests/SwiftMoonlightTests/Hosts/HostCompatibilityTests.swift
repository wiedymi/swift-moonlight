import Foundation
import Testing
@testable import SwiftMoonlight

@Test
func hostRefreshBuildsApolloCompatibilityProfile() async throws {
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
            )
        )
    )

    let refreshed = try await client.refreshHost(host.id)

    #expect(refreshed.kind == .apollo)
    #expect(refreshed.compatibilityProfile.kind == .apollo)
    #expect(refreshed.compatibilityProfile.quirks.contains(.apolloPerClientPermissions))
    #expect(refreshed.capabilities.supportsOTPAuth)
    #expect(refreshed.capabilities.supportsInputOnlySession)
    #expect(refreshed.capabilities.requiresPerClientAuthorization)
}

@Test
func hostRefreshBuildsSunshineCompatibilityProfile() async throws {
    let host = MoonlightHost(
        id: HostID(),
        name: "Sunshine Host",
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
            )
        )
    )

    let refreshed = try await client.refreshHost(host.id)

    #expect(refreshed.kind == .sunshine)
    #expect(refreshed.compatibilityProfile.kind == .sunshine)
    #expect(refreshed.compatibilityProfile.quirks.values.isEmpty)
    #expect(!refreshed.capabilities.supportsOTPAuth)
    #expect(!refreshed.capabilities.supportsInputOnlySession)
    #expect(!refreshed.capabilities.requiresPerClientAuthorization)
}

@Test
func hostRefreshTreatsApolloPermissionFieldAsApolloEvenWithSunshineVersionShape() async throws {
    let host = MoonlightHost(
        id: HostID(),
        name: "Live Apollo Host",
        endpoint: .init(address: "apollo-host.local", port: 47989),
        kind: .unknown,
        pairingState: .unpaired,
        capabilities: .default
    )
    let liveStyleServerInfo = Data(
        """
        <?xml version="1.0" encoding="utf-8"?>
        <root status_code="200"><hostname>apollo-host</hostname><appversion>7.1.431.-1</appversion><GfeVersion>3.23.0.74</GfeVersion><uniqueid>11111111-2222-3333-4444-555555555555</uniqueid><HttpsPort>47984</HttpsPort><ExternalPort>47989</ExternalPort><MaxLumaPixelsHEVC>1869449984</MaxLumaPixelsHEVC><mac>00:00:00:00:00:00</mac><Permission>0</Permission><LocalIP>192.0.2.28</LocalIP><ServerCodecModeSupport>1835777</ServerCodecModeSupport><PairStatus>0</PairStatus><currentgame>0</currentgame><currentgameuuid/><state>SUNSHINE_SERVER_FREE</state></root>
        """.utf8
    )
    let client = MoonlightClient(
        configuration: .init(
            hostStore: InMemoryHostStore(hosts: [host]),
            identityStore: InMemoryIdentityStore(),
            clock: TestClock(),
            logger: TestLogger(),
            metricsSink: RecordingMetricsSink(),
            hostService: FixtureHostService(
                serverInfoData: liveStyleServerInfo,
                appListData: try fixtureData(named: "applist_sunshine.xml")
            )
        )
    )

    let refreshed = try await client.refreshHost(host.id)

    #expect(refreshed.kind == .apollo)
    #expect(refreshed.compatibilityProfile.kind == .apollo)
    #expect(refreshed.compatibilityProfile.quirks.contains(.apolloPerClientPermissions))
    #expect(refreshed.capabilities.supportsOTPAuth)
    #expect(refreshed.capabilities.supportsInputOnlySession)
    #expect(refreshed.capabilities.requiresPerClientAuthorization)
}
