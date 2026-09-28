import Foundation

public actor RecordingHTTPClient: HTTPClient {
    public struct Response: Sendable {
        public var data: Data
        public var statusCode: Int

        public init(data: Data, statusCode: Int = 200) {
            self.data = data
            self.statusCode = statusCode
        }
    }

    private let response: Response
    private var requests: [(url: URL, headers: [String: String])] = []

    public init(response: Response) {
        self.response = response
    }

    public func get(url: URL, headers: [String : String]) async throws -> (Data, HTTPURLResponse) {
        requests.append((url, headers))
        let response = HTTPURLResponse(
            url: url,
            statusCode: self.response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )!
        return (self.response.data, response)
    }

    public func recordedRequests() -> [(url: URL, headers: [String: String])] {
        requests
    }
}

public actor FixturePairingTransport: PairingTransport {
    private let responses: [Data]
    private var index = 0
    private var requests: [(hostID: HostID, queryItems: [URLQueryItem])] = []
    private var unpairRequests: [(hostID: HostID, queryItems: [URLQueryItem])] = []

    public init(responses: [Data]) {
        self.responses = responses
    }

    public func sendPairingRequest(
        to host: MoonlightHost,
        queryItems: [URLQueryItem]
    ) async throws -> Data {
        requests.append((host.id, queryItems))
        guard index < responses.count else {
            throw MoonlightError(.pairingRejected, message: "No more fixture pairing responses available")
        }
        defer { index += 1 }
        return responses[index]
    }

    public func recordedRequests() -> [(hostID: HostID, queryItems: [URLQueryItem])] {
        requests
    }

    public func sendUnpairRequest(
        to host: MoonlightHost,
        queryItems: [URLQueryItem]
    ) async throws -> Data {
        unpairRequests.append((host.id, queryItems))
        return Data()
    }

    public func recordedUnpairRequests() -> [(hostID: HostID, queryItems: [URLQueryItem])] {
        unpairRequests
    }
}

public actor FixturePairingClientService: PairingClientService {
    private let result: PairingResult
    private var requests: [(hostID: HostID, auth: PairingAuth, identityID: UUID)] = []
    private var unpairRequests: [(hostID: HostID, identityID: UUID)] = []

    public init(result: PairingResult) {
        self.result = result
    }

    public func pair(host: MoonlightHost, auth: PairingAuth, identity: ClientIdentity) async throws -> PairingResult {
        requests.append((host.id, auth, identity.identifier))
        return result
    }

    public func recordedRequests() -> [(hostID: HostID, auth: PairingAuth, identityID: UUID)] {
        requests
    }

    public func unpair(host: MoonlightHost, identity: ClientIdentity) async throws {
        unpairRequests.append((host.id, identity.identifier))
    }

    public func recordedUnpairRequests() -> [(hostID: HostID, identityID: UUID)] {
        unpairRequests
    }
}

public actor FixtureRTSPTransport: RTSPTransport {
    private let responses: [RTSPResponse]
    private var index = 0
    private var requests: [RTSPRequest] = []
    private var encryptionKeys: [Data?] = []

    public init(responses: [RTSPResponse]) {
        self.responses = responses
    }

    public func transact(sessionURL: String, request: RTSPRequest, encryptionKey: Data?) async throws -> RTSPResponse {
        _ = sessionURL
        requests.append(request)
        encryptionKeys.append(encryptionKey)
        guard index < responses.count else {
            throw MoonlightError(.unsupportedOperation, message: "No more RTSP fixture responses available")
        }
        defer { index += 1 }
        return responses[index]
    }

    public func recordedRequests() -> [RTSPRequest] {
        requests
    }

    public func recordedEncryptionKeys() -> [Data?] {
        encryptionKeys
    }
}
