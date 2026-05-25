import Foundation
import Testing
@testable import SwiftMoonlight

@Test
func buildsServerInfoURLWithIdentityQuery() throws {
    let builder = HostRequestBuilder()
    let host = MoonlightHost(
        id: HostID(),
        name: "Host",
        endpoint: .init(address: "192.168.1.10", port: 47990, securePort: 47984),
        kind: .sunshine,
        pairingState: .paired,
        capabilities: .default
    )
    let url = try builder.makeServerInfoURL(
        for: host,
        uniqueID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")
    )

    #expect(url.absoluteString == "http://192.168.1.10:47990/serverinfo?uniqueid=11111111-2222-3333-4444-555555555555")
}

@Test
func httpHostServiceRequestsServerInfoAndAppList() async throws {
    let responseData = try fixtureData(named: "serverinfo_sunshine_paired.xml")
    let httpClient = RecordingHTTPClient(response: .init(data: responseData))
    let identityStore = InMemoryIdentityStore(
        identity: ClientIdentity(
            identifier: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            displayName: "Tester"
        )
    )
    let service = HTTPHostService(client: httpClient, identityStore: identityStore)
    let host = MoonlightHost(
        id: HostID(),
        name: "Host",
        endpoint: .init(address: "192.168.1.10", port: 47990, securePort: 47984),
        kind: .sunshine,
        pairingState: .paired,
        capabilities: .default
    )

    _ = try await service.fetchServerInfo(for: host)
    _ = try await service.fetchAppList(for: host)
    let requests = await httpClient.recordedRequests()

    #expect(requests.count == 2)
    #expect(requests[0].url.scheme == "https")
    #expect(requests[0].url.port == 47984)
    #expect(requests[0].url.path == "/serverinfo")
    #expect(requests[0].url.query?.contains("uniqueid=11111111-2222-3333-4444-555555555555") == true)
    #expect(requests[1].url.scheme == "https")
    #expect(requests[1].url.port == 47984)
    #expect(requests[1].url.path == "/applist")
    #expect(requests[1].url.query?.contains("uniqueid=11111111-2222-3333-4444-555555555555") == true)
    #expect(requests[1].headers["Accept"] == "application/xml, text/xml;q=0.9, */*;q=0.8")
}

@Test
func httpHostServiceWrapsTransportFailuresWithRequestURL() async throws {
    let identityStore = InMemoryIdentityStore(
        identity: ClientIdentity(
            identifier: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            displayName: "Tester"
        )
    )
    let service = HTTPHostService(
        client: FailingHTTPClient(error: URLError(.timedOut)),
        identityStore: identityStore
    )
    let host = MoonlightHost(
        id: HostID(),
        name: "Host",
        endpoint: .init(address: "192.168.1.10", port: 47990, securePort: 47984),
        kind: .sunshine,
        pairingState: .paired,
        capabilities: .default
    )

    do {
        _ = try await service.fetchServerInfo(for: host)
        Issue.record("Expected fetchServerInfo to fail")
    } catch let error as MoonlightError {
        #expect(error.code == .networkRequestFailed)
        #expect(error.message.contains("serverinfo request"))
        #expect(error.message.contains("http://192.168.1.10:47990/serverinfo"))
    }
}

@Test
func httpHostServiceFallsBackToPlainServerInfoWhenSecureServerInfoFails() async throws {
    let responseData = try fixtureData(named: "serverinfo_sunshine_paired.xml")
    let httpClient = SequencedHTTPClient(results: [
        .failure(URLError(.cannotConnectToHost)),
        .success(responseData),
    ])
    let identityStore = InMemoryIdentityStore(
        identity: ClientIdentity(
            identifier: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            displayName: "Tester"
        )
    )
    let service = HTTPHostService(client: httpClient, identityStore: identityStore)
    let host = MoonlightHost(
        id: HostID(),
        name: "Host",
        endpoint: .init(address: "192.168.1.10", port: 47990, securePort: 47984),
        kind: .sunshine,
        pairingState: .paired,
        capabilities: .default
    )

    let data = try await service.fetchServerInfo(for: host)
    let requests = await httpClient.recordedRequests()

    #expect(data == responseData)
    #expect(requests.map { $0.url.scheme } == ["https", "http"])
    #expect(requests[0].url.port == 47984)
    #expect(requests[1].url.port == 47990)
}

@Test
func buildsCancelURLWithIdentityQueryOnSecurePort() async throws {
    let responseData = Data(#"<?xml version="1.0" encoding="utf-8"?><root status_code="200"><cancel>1</cancel></root>"#.utf8)
    let httpClient = RecordingHTTPClient(response: .init(data: responseData))
    let identityStore = InMemoryIdentityStore(
        identity: ClientIdentity(
            identifier: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            displayName: "Tester"
        )
    )
    let service = HTTPHostService(client: httpClient, identityStore: identityStore)
    let host = MoonlightHost(
        id: HostID(),
        name: "Host",
        endpoint: .init(address: "192.168.1.10", port: 47990, securePort: 47984),
        kind: .sunshine,
        pairingState: .paired,
        capabilities: .default
    )

    try await service.cancelCurrentApp(for: host)
    let requests = await httpClient.recordedRequests()

    #expect(requests.count == 1)
    #expect(requests[0].url.scheme == "https")
    #expect(requests[0].url.port == 47984)
    #expect(requests[0].url.path == "/cancel")
    #expect(requests[0].url.query?.contains("uniqueid=11111111-2222-3333-4444-555555555555") == true)
}

@Test
func httpLaunchTransportRequestsLaunchEndpoint() async throws {
    let httpClient = RecordingHTTPClient(response: .init(data: try fixtureData(named: "launch_sunshine_success.xml")))
    let transport = HTTPLaunchTransport(client: httpClient)
    let host = MoonlightHost(
        id: HostID(),
        name: "Host",
        endpoint: .init(address: "192.168.1.10", port: 47990, securePort: 47984),
        kind: .sunshine,
        pairingState: .paired,
        capabilities: .default
    )

    _ = try await transport.sendLaunchRequest(
        to: host,
        queryItems: [
            .init(name: "appid", value: "desktop"),
            .init(name: "mode", value: "1920x1080x60"),
        ]
    )
    let requests = await httpClient.recordedRequests()

    #expect(requests.count == 1)
    #expect(requests[0].url.scheme == "https")
    #expect(requests[0].url.port == 47984)
    #expect(requests[0].url.path == "/launch")
    #expect(requests[0].url.query?.contains("appid=desktop") == true)
    #expect(requests[0].url.query?.contains("mode=1920x1080x60") == true)
}

private struct FailingHTTPClient: HTTPClient {
    var error: URLError

    func get(url: URL, headers: [String : String]) async throws -> (Data, HTTPURLResponse) {
        _ = url
        _ = headers
        throw error
    }
}

private enum SequencedHTTPResult: Sendable {
    case success(Data)
    case failure(URLError)
}

private actor SequencedHTTPClient: HTTPClient {
    private var results: [SequencedHTTPResult]
    private var requests: [(url: URL, headers: [String: String])] = []

    init(results: [SequencedHTTPResult]) {
        self.results = results
    }

    func get(url: URL, headers: [String : String]) async throws -> (Data, HTTPURLResponse) {
        requests.append((url, headers))
        guard !results.isEmpty else {
            throw URLError(.badServerResponse)
        }

        let result = results.removeFirst()
        switch result {
        case .success(let data):
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [:]
            )!
            return (data, response)
        case .failure(let error):
            throw error
        }
    }

    func recordedRequests() -> [(url: URL, headers: [String: String])] {
        requests
    }
}
