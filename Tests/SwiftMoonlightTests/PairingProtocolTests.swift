import Foundation
import Testing
@testable import SwiftMoonlight

@Test
func parsesPairingResponseFields() throws {
    let data = try fixtureData(named: "pair_clientchallenge_success.xml")
    let response = try PairingResponseParser().parse(data)

    #expect(response.statusCode == 200)
    #expect(response.isPaired == true)
    #expect(response.challengeResponseHex == "11223344")
}

@Test
func buildsApolloGetServerCertQueryWithDeviceName() {
    let builder = PairingRequestBuilder()
    let host = MoonlightHost(
        id: HostID(),
        name: "Apollo",
        endpoint: .init(address: "192.168.1.11", port: 47990),
        kind: .apollo,
        pairingState: .unpaired,
        capabilities: .default
    )
    let items = builder.getServerCertQuery(
        host: host,
        uniqueID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        clientCertificateHex: "AABB",
        saltHex: "CCDD",
        deviceName: "iPad Pro",
        otpAuthHex: "EEFF"
    )

    #expect(items.contains(.init(name: "phrase", value: "getservercert")))
    #expect(items.contains(.init(name: "devicename", value: "iPad Pro")))
    #expect(items.contains(.init(name: "updateState", value: "1")))
    #expect(items.contains(.init(name: "otpauth", value: "eeff")))
}

@Test
func buildsSunshineGetServerCertQueryWithCompatibilityDeviceMarkers() {
    let builder = PairingRequestBuilder()
    let host = MoonlightHost(
        id: HostID(),
        name: "Sunshine",
        endpoint: .init(address: "192.168.1.10", port: 47990),
        kind: .sunshine,
        pairingState: .unpaired,
        capabilities: .default
    )
    let items = builder.getServerCertQuery(
        host: host,
        uniqueID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        clientCertificateHex: "AABB",
        saltHex: "CCDD",
        deviceName: "MacBook Pro"
    )

    #expect(items.contains(.init(name: "devicename", value: "roth")))
    #expect(items.contains(.init(name: "updateState", value: "1")))
}

@Test
func pairingServiceExecutesOrderedHandshake() async throws {
    let host = MoonlightHost(
        id: HostID(),
        name: "Sunshine",
        endpoint: .init(address: "192.168.1.10", port: 47990),
        kind: .sunshine,
        pairingState: .unpaired,
        capabilities: .default
    )
    let material = PairingMaterial(
        uniqueID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        clientCertificateHex: "AABBCCDD",
        saltHex: "01020304",
        clientChallengeHex: "1111",
        serverChallengeResponseHex: "2222",
        clientPairingSecretHex: "3333",
        deviceName: "MacBook Pro"
    )
    let transport = FixturePairingTransport(responses: [
        try fixtureData(named: "pair_getservercert_success.xml"),
        try fixtureData(named: "pair_clientchallenge_success.xml"),
        try fixtureData(named: "pair_serverchallengeresp_success.xml"),
        try fixtureData(named: "pair_clientpairingsecret_success.xml"),
    ])
    let service = PairingService(transport: transport)

    let exchange = try await service.performHandshake(host: host, material: material)
    let requests = await transport.recordedRequests()

    #expect(exchange.serverCertificateHex == "AABBCCDD")
    #expect(exchange.challengeResponseHex == "11223344")
    #expect(exchange.pairingSecretHex == "55667788")
    #expect(requests.count == 4)
    #expect(requests[0].queryItems.contains(.init(name: "phrase", value: "getservercert")))
    #expect(requests[1].queryItems.contains(.init(name: "clientchallenge", value: "1111")))
    #expect(requests[2].queryItems.contains(.init(name: "serverchallengeresp", value: "2222")))
    #expect(requests[3].queryItems.contains(.init(name: "clientpairingsecret", value: "3333")))
}

@Test
func httpPairingTransportTargetsPairEndpoint() async throws {
    let client = RecordingHTTPClient(response: .init(data: try fixtureData(named: "pair_getservercert_success.xml")))
    let transport = HTTPPairingTransport(client: client)
    let host = MoonlightHost(
        id: HostID(),
        name: "Sunshine",
        endpoint: .init(address: "192.168.1.10", port: 47990),
        kind: .sunshine,
        pairingState: .unpaired,
        capabilities: .default
    )

    _ = try await transport.sendPairingRequest(
        to: host,
        queryItems: [
            .init(name: "uniqueid", value: "u"),
            .init(name: "phrase", value: "getservercert"),
        ]
    )
    let requests = await client.recordedRequests()

    #expect(requests.count == 1)
    #expect(requests[0].url.path == "/pair")
    #expect(requests[0].url.query?.contains("phrase=getservercert") == true)
}

@Test
func httpPairingTransportTargetsUnpairEndpoint() async throws {
    let client = RecordingHTTPClient(response: .init(data: Data()))
    let transport = HTTPPairingTransport(client: client)
    let host = MoonlightHost(
        id: HostID(),
        name: "Sunshine",
        endpoint: .init(address: "192.168.1.10", port: 47990),
        kind: .sunshine,
        pairingState: .paired,
        capabilities: .default
    )

    _ = try await transport.sendUnpairRequest(
        to: host,
        queryItems: [
            .init(name: "uniqueid", value: "u"),
        ]
    )
    let requests = await client.recordedRequests()

    #expect(requests.count == 1)
    #expect(requests[0].url.path == "/unpair")
    #expect(requests[0].url.query?.contains("uniqueid=u") == true)
}
