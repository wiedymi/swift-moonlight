import Foundation

public struct HTTPHostService: HostService {
    public let client: any HTTPClient
    public let requestBuilder: HostRequestBuilder
    public let identityStore: any IdentityStore

    public init(
        client: any HTTPClient,
        requestBuilder: HostRequestBuilder = HostRequestBuilder(),
        identityStore: any IdentityStore
    ) {
        self.client = client
        self.requestBuilder = requestBuilder
        self.identityStore = identityStore
    }

    public func fetchServerInfo(for host: MoonlightHost) async throws -> Data {
        let identity = try await identityStore.loadOrCreateIdentity()
        if host.endpoint.securePort != nil {
            do {
                let secureURL = try requestBuilder.makeSecureServerInfoURL(for: host, uniqueID: identity.identifier)
                let (data, response) = try await get(url: secureURL, operation: "secure serverinfo")
                try validate(response: response, body: data)
                return data
            } catch {
                // Apollo only exposes paired permission state on the certificate-authenticated
                // endpoint, but discovery and unpaired hosts may still require plain HTTP.
            }
        }

        let url = try requestBuilder.makeServerInfoURL(for: host, uniqueID: identity.identifier)
        let (data, response) = try await get(url: url, operation: "serverinfo")
        try validate(response: response, body: data)
        return data
    }

    public func fetchAppList(for host: MoonlightHost) async throws -> Data {
        let identity = try await identityStore.loadOrCreateIdentity()
        let url = try requestBuilder.makeAppListURL(for: host, uniqueID: identity.identifier)
        let (data, response) = try await get(url: url, operation: "applist")
        try validate(response: response, body: data)
        return data
    }

    public func cancelCurrentApp(for host: MoonlightHost) async throws {
        let identity = try await identityStore.loadOrCreateIdentity()
        let url = try requestBuilder.makeCancelURL(for: host, uniqueID: identity.identifier)
        let (data, response) = try await get(url: url, operation: "cancel")
        try validate(response: response, body: data)
    }

    private var defaultHeaders: [String: String] {
        ["Accept": "application/xml, text/xml;q=0.9, */*;q=0.8"]
    }

    private func get(
        url: URL,
        operation: String
    ) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await client.get(url: url, headers: defaultHeaders)
        } catch let error as MoonlightError {
            throw error
        } catch {
            throw MoonlightError(
                .networkRequestFailed,
                message: "\(operation) request to \(url.absoluteString) failed: \(error.localizedDescription)"
            )
        }
    }

    private func validate(response: HTTPURLResponse, body: Data) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw MoonlightError(.unsupportedOperation, message: "HTTP request failed with status \(response.statusCode): \(String(decoding: body, as: UTF8.self))")
        }
    }
}
