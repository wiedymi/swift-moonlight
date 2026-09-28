import Foundation

public struct LaunchSessionService: SessionService {
    public let transport: any SessionLaunchTransport
    public let queryBuilder: LaunchQueryBuilder
    public let responseParser: LaunchResponseParser
    public let queryOptionsProvider: @Sendable (MoonlightHost, StreamConfiguration, ClientIdentity) throws -> LaunchQueryOptions

    public init(
        transport: any SessionLaunchTransport,
        queryBuilder: LaunchQueryBuilder = LaunchQueryBuilder(),
        responseParser: LaunchResponseParser = LaunchResponseParser(),
        queryOptionsProvider: @escaping @Sendable (MoonlightHost, StreamConfiguration, ClientIdentity) throws -> LaunchQueryOptions
    ) {
        self.transport = transport
        self.queryBuilder = queryBuilder
        self.responseParser = responseParser
        self.queryOptionsProvider = queryOptionsProvider
    }

    public func launchSession(
        for host: MoonlightHost,
        appID: RemoteApp.ID,
        configuration: StreamConfiguration,
        identity: ClientIdentity
    ) async throws -> NegotiatedSession {
        let options = try queryOptionsProvider(host, configuration, identity)
        let query = queryBuilder.buildLaunchQuery(
            host: host,
            appID: appID,
            configuration: configuration,
            identity: identity,
            options: options
        )
        let response = try await transport.sendLaunchRequest(to: host, queryItems: query)
        var negotiated = try responseParser.negotiatedSession(from: response, host: host, appID: appID)
        negotiated.remoteInputSecrets = RemoteInputSecrets(
            key: try parseRemoteInputKey(options.remoteInputKeyHex),
            keyID: options.remoteInputKeyID
        )
        return negotiated
    }

    private func parseRemoteInputKey(_ hex: String) throws -> Data {
        let key = try Data(hexString: hex)
        guard key.count == 16 else {
            throw MoonlightError(.invalidLaunchResponse, message: "Launch query remote input key must be a 16-byte hex string")
        }
        return key
    }
}
