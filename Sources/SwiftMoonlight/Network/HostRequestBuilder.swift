import Foundation

public struct HostRequestBuilder: Sendable {
    public var scheme: String

    public init(scheme: String = "http") {
        self.scheme = scheme
    }

    public func makeServerInfoURL(for host: MoonlightHost, uniqueID: UUID?) throws -> URL {
        try makeURL(
            for: host,
            path: "/serverinfo",
            queryItems: uniqueID.map { [URLQueryItem(name: "uniqueid", value: $0.uuidString.lowercased())] } ?? []
        )
    }

    public func makeSecureServerInfoURL(for host: MoonlightHost, uniqueID: UUID?) throws -> URL {
        try makeURL(
            address: host.endpoint.address,
            port: host.endpoint.securePort ?? host.endpoint.port,
            scheme: "https",
            path: "/serverinfo",
            queryItems: uniqueID.map { [URLQueryItem(name: "uniqueid", value: $0.uuidString.lowercased())] } ?? []
        )
    }

    public func makeAppListURL(for host: MoonlightHost, uniqueID: UUID?) throws -> URL {
        try makeURL(
            address: host.endpoint.address,
            port: host.endpoint.securePort ?? host.endpoint.port,
            scheme: "https",
            path: "/applist",
            queryItems: uniqueID.map { [URLQueryItem(name: "uniqueid", value: $0.uuidString.lowercased())] } ?? []
        )
    }

    public func makeLaunchURL(for host: MoonlightHost, queryItems: [URLQueryItem]) throws -> URL {
        try makeURL(
            address: host.endpoint.address,
            port: host.endpoint.securePort ?? host.endpoint.port,
            scheme: "https",
            path: "/launch",
            queryItems: queryItems
        )
    }

    public func makeCancelURL(for host: MoonlightHost, uniqueID: UUID?) throws -> URL {
        try makeURL(
            address: host.endpoint.address,
            port: host.endpoint.securePort ?? host.endpoint.port,
            scheme: "https",
            path: "/cancel",
            queryItems: uniqueID.map { [URLQueryItem(name: "uniqueid", value: $0.uuidString.lowercased())] } ?? []
        )
    }

    public func makePairingURL(for host: MoonlightHost, queryItems: [URLQueryItem]) throws -> URL {
        try makeURL(for: host, path: "/pair", queryItems: queryItems)
    }

    public func makeUnpairURL(for host: MoonlightHost, queryItems: [URLQueryItem]) throws -> URL {
        try makeURL(for: host, path: "/unpair", queryItems: queryItems)
    }

    private func makeURL(for host: MoonlightHost, path: String, queryItems: [URLQueryItem]) throws -> URL {
        try makeURL(
            address: host.endpoint.address,
            port: host.endpoint.port,
            scheme: scheme,
            path: path,
            queryItems: queryItems
        )
    }

    private func makeURL(
        address: String,
        port: Int,
        scheme: String,
        path: String,
        queryItems: [URLQueryItem]
    ) throws -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = address
        components.port = port
        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components.url else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to build URL for host \(address)")
        }

        return url
    }
}
