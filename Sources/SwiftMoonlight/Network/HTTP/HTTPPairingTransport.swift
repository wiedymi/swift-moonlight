import Foundation

public struct HTTPPairingTransport: PairingTransport {
    public let client: any HTTPClient
    public let requestBuilder: HostRequestBuilder

    public init(
        client: any HTTPClient,
        requestBuilder: HostRequestBuilder = HostRequestBuilder()
    ) {
        self.client = client
        self.requestBuilder = requestBuilder
    }

    public func sendPairingRequest(
        to host: MoonlightHost,
        queryItems: [URLQueryItem]
    ) async throws -> Data {
        let url = try requestBuilder.makePairingURL(for: host, queryItems: queryItems)
        let (data, response) = try await client.get(
            url: url,
            headers: ["Accept": "application/xml, text/xml;q=0.9, */*;q=0.8"]
        )

        guard (200..<300).contains(response.statusCode) else {
            throw MoonlightError(.pairingRejected, message: "Pairing request failed with HTTP status \(response.statusCode)")
        }

        return data
    }

    public func sendUnpairRequest(
        to host: MoonlightHost,
        queryItems: [URLQueryItem]
    ) async throws -> Data {
        let url = try requestBuilder.makeUnpairURL(for: host, queryItems: queryItems)
        let (data, response) = try await client.get(
            url: url,
            headers: ["Accept": "application/xml, text/xml;q=0.9, */*;q=0.8"]
        )

        guard (200..<300).contains(response.statusCode) else {
            throw MoonlightError(.pairingRejected, message: "Unpair request failed with HTTP status \(response.statusCode)")
        }

        return data
    }
}
