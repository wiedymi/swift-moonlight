import Foundation

public struct HTTPLaunchTransport: SessionLaunchTransport {
    public let client: any HTTPClient
    public let requestBuilder: HostRequestBuilder

    public init(
        client: any HTTPClient,
        requestBuilder: HostRequestBuilder = HostRequestBuilder()
    ) {
        self.client = client
        self.requestBuilder = requestBuilder
    }

    public func sendLaunchRequest(
        to host: MoonlightHost,
        queryItems: [URLQueryItem]
    ) async throws -> Data {
        let url = try requestBuilder.makeLaunchURL(for: host, queryItems: queryItems)
        let (data, response) = try await client.get(
            url: url,
            headers: ["Accept": "application/xml, text/xml;q=0.9, */*;q=0.8"]
        )

        guard (200..<300).contains(response.statusCode) else {
            throw MoonlightError(.launchRejected, message: "Launch request failed with HTTP status \(response.statusCode)")
        }

        return data
    }
}
