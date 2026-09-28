import Foundation

public actor FixtureHostService: HostService {
    private let serverInfoData: Data
    private let appListData: Data
    private var cancelledHostIDs: [HostID] = []

    public init(serverInfoData: Data, appListData: Data) {
        self.serverInfoData = serverInfoData
        self.appListData = appListData
    }

    public func fetchServerInfo(for host: MoonlightHost) async throws -> Data {
        _ = host
        return serverInfoData
    }

    public func fetchAppList(for host: MoonlightHost) async throws -> Data {
        _ = host
        return appListData
    }

    public func cancelCurrentApp(for host: MoonlightHost) async throws {
        cancelledHostIDs.append(host.id)
    }

    public func recordedCancelledHostIDs() -> [HostID] {
        cancelledHostIDs
    }
}

public actor FixtureSessionService: SessionService {
    private let negotiatedSession: NegotiatedSession
    private var launchedHostIDs: [HostID] = []
    private var launchedAppIDs: [RemoteApp.ID] = []
    private var launchConfigurations: [StreamConfiguration] = []

    public init(negotiatedSession: NegotiatedSession) {
        self.negotiatedSession = negotiatedSession
    }

    public func launchSession(
        for host: MoonlightHost,
        appID: RemoteApp.ID,
        configuration: StreamConfiguration,
        identity: ClientIdentity
    ) async throws -> NegotiatedSession {
        _ = identity
        launchedHostIDs.append(host.id)
        launchedAppIDs.append(appID)
        launchConfigurations.append(configuration)
        return negotiatedSession
    }

    public func recordedHostIDs() -> [HostID] {
        launchedHostIDs
    }

    public func recordedAppIDs() -> [RemoteApp.ID] {
        launchedAppIDs
    }

    public func recordedConfigurations() -> [StreamConfiguration] {
        launchConfigurations
    }
}

public actor RecordingLaunchTransport: SessionLaunchTransport {
    private let responseData: Data
    private var requests: [(hostID: HostID, queryItems: [URLQueryItem])] = []

    public init(responseData: Data) {
        self.responseData = responseData
    }

    public func sendLaunchRequest(
        to host: MoonlightHost,
        queryItems: [URLQueryItem]
    ) async throws -> Data {
        requests.append((host.id, queryItems))
        return responseData
    }

    public func recordedRequests() -> [(hostID: HostID, queryItems: [URLQueryItem])] {
        requests
    }
}
