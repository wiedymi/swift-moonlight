import Foundation
import Testing
@testable import SwiftMoonlight

@Test
func parsesSunshineLaunchSuccessFixture() throws {
    let parser = LaunchResponseParser()
    let data = try fixtureData(named: "launch_sunshine_success.xml")

    let response = try parser.parseLaunchResponse(data)

    #expect(response.statusCode == 200)
    #expect(response.didStartSession == true)
    #expect(response.didResumeSession == false)
    #expect(response.sessionURL == "rtsp://192.168.1.10:47998")
}

@Test
func parsesApolloResumeFixture() throws {
    let parser = LaunchResponseParser()
    let data = try fixtureData(named: "launch_apollo_resume.xml")

    let response = try parser.parseLaunchResponse(data)

    #expect(response.statusCode == 200)
    #expect(response.didStartSession == false)
    #expect(response.didResumeSession == true)
    #expect(response.sessionURL == "rtsp://192.168.1.11:48010")
}

@Test
func rejectsLaunchResponseWithFailureStatus() throws {
    let parser = LaunchResponseParser()
    let data = try fixtureData(named: "launch_sunshine_rejected.xml")
    let host = MoonlightHost(
        id: HostID(),
        name: "Sunshine Host",
        endpoint: .init(address: "192.168.1.10", port: 47989),
        kind: .sunshine,
        pairingState: .paired,
        capabilities: .default
    )

    #expect(throws: MoonlightError.self) {
        _ = try parser.negotiatedSession(from: data, host: host, appID: "desktop")
    }
}

@Test
func launchSessionServiceBuildsQueryAndParsesResponse() async throws {
    let host = MoonlightHost(
        id: HostID(),
        name: "Sunshine Host",
        endpoint: .init(address: "192.168.1.10", port: 47989),
        kind: .sunshine,
        pairingState: .paired,
        capabilities: .default
    )
    let identity = ClientIdentity(
        identifier: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        displayName: "Test Client"
    )
    let transport = RecordingLaunchTransport(responseData: try fixtureData(named: "launch_sunshine_success.xml"))
    let service = LaunchSessionService(
        transport: transport,
        queryOptionsProvider: { _, _, _ in
            LaunchQueryOptions(
                remoteInputKeyHex: "00112233445566778899AABBCCDDEEFF",
                remoteInputKeyID: 42
            )
        }
    )

    let negotiated = try await service.launchSession(
        for: host,
        appID: "desktop",
        configuration: .default1080p60,
        identity: identity
    )
    let requests = await transport.recordedRequests()
    let expectedKey = Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])

    #expect(negotiated.rtspSessionURL == "rtsp://192.168.1.10:47998")
    #expect(negotiated.remoteInputSecrets?.key == expectedKey)
    #expect(negotiated.remoteInputSecrets?.keyID == 42)
    #expect(requests.count == 1)
    #expect(requests[0].hostID == host.id)
    #expect(requests[0].queryItems.contains(.init(name: "appid", value: "desktop")))
    #expect(requests[0].queryItems.contains(.init(name: "mode", value: "1920x1080x60")))
    #expect(requests[0].queryItems.contains(.init(name: "additionalStates", value: "1")))
    #expect(requests[0].queryItems.contains(.init(name: "remoteControllersBitmap", value: "0")))
    #expect(requests[0].queryItems.contains(.init(name: "gcpersist", value: "0")))
}

@Test
func launchSessionDoesNotSendRequestWhenKeyCreationFails() async throws {
    let host = MoonlightHost(
        id: HostID(),
        name: "Sunshine Host",
        endpoint: .init(address: "192.168.1.10", port: 47989),
        kind: .sunshine,
        pairingState: .paired,
        capabilities: .default
    )
    let transport = RecordingLaunchTransport(responseData: Data())
    let service = LaunchSessionService(transport: transport) { _, _, _ in
        throw MoonlightError(.unsupportedOperation, message: "Random input failed")
    }

    await #expect(throws: MoonlightError.self) {
        _ = try await service.launchSession(
            for: host,
            appID: "desktop",
            configuration: .default1080p60,
            identity: ClientIdentity(identifier: UUID(), displayName: "Test Client")
        )
    }
    #expect(await transport.recordedRequests().isEmpty)
}

@Test
func productionLaunchDefaultsRequestApolloVirtualDisplay() async throws {
    let host = MoonlightHost(
        id: HostID(),
        name: "Apollo Host",
        endpoint: .init(address: "192.168.1.11", port: 47989, securePort: 47984),
        kind: .apollo,
        pairingState: .paired,
        capabilities: .inferred(for: .apollo, codecSupportFlags: 0x0002_0200)
    )
    let identity = ClientIdentity(
        identifier: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
        displayName: "Test Client"
    )
    let httpClient = RecordingHTTPClient(response: .init(data: try fixtureData(named: "launch_apollo_resume.xml")))
    let configuration = ProductionClientFactory.configuration(
        hostStore: InMemoryHostStore(hosts: [host]),
        identityStore: InMemoryIdentityStore(identity: identity),
        httpClient: httpClient
    )
    let service = try #require(configuration.sessionService)

    _ = try await service.launchSession(
        for: host,
        appID: "desktop",
        configuration: .default1080p60,
        identity: identity
    )
    let requests = await httpClient.recordedRequests()

    #expect(requests.count == 1)
    #expect(requests[0].url.scheme == "https")
    #expect(requests[0].url.query?.contains("virtualDisplay=1") == true)
    #expect(requests[0].url.query?.contains("scaleFactor=100") == true)
}
