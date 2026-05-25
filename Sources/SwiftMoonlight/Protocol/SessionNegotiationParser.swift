import Foundation

public struct LaunchResponse: Sendable, Equatable {
    public var statusCode: Int
    public var statusMessage: String?
    public var sessionURL: String?
    public var didStartSession: Bool
    public var didResumeSession: Bool

    public init(
        statusCode: Int,
        statusMessage: String?,
        sessionURL: String?,
        didStartSession: Bool,
        didResumeSession: Bool
    ) {
        self.statusCode = statusCode
        self.statusMessage = statusMessage
        self.sessionURL = sessionURL
        self.didStartSession = didStartSession
        self.didResumeSession = didResumeSession
    }
}

public struct LaunchResponseParser: Sendable {
    public init() {}

    public func parseLaunchResponse(_ data: Data) throws -> LaunchResponse {
        let document = try XMLScalarDocument(data: data)

        guard let statusCodeText = document.attribute(named: "status_code", onElementNamed: "root"),
              let statusCode = Int(statusCodeText)
        else {
            throw MoonlightError(.invalidLaunchResponse, message: "Launch response is missing root status_code")
        }

        let didStartSession = document.firstValue(forElementNamed: "gamesession") == "1"
        let didResumeSession = document.firstValue(forElementNamed: "resume") == "1"
        let sessionURL = document.firstValue(forElementNamed: "sessionUrl0")
        let statusMessage = document.attribute(named: "status_message", onElementNamed: "root")

        if statusCode == 200 && !didStartSession && !didResumeSession {
            throw MoonlightError(.invalidLaunchResponse, message: "Launch response succeeded without gamesession or resume marker")
        }

        return LaunchResponse(
            statusCode: statusCode,
            statusMessage: statusMessage,
            sessionURL: sessionURL,
            didStartSession: didStartSession,
            didResumeSession: didResumeSession
        )
    }

    public func negotiatedSession(
        from data: Data,
        host: MoonlightHost,
        appID: RemoteApp.ID
    ) throws -> NegotiatedSession {
        let response = try parseLaunchResponse(data)

        guard response.statusCode == 200 else {
            throw MoonlightError(.launchRejected, message: response.statusMessage ?? "Launch rejected by host")
        }

        guard let sessionURL = response.sessionURL else {
            throw MoonlightError(.invalidLaunchResponse, message: "Launch response is missing sessionUrl0")
        }

        return NegotiatedSession(
            hostID: host.id,
            appID: appID,
            rtspSessionURL: sessionURL
        )
    }
}
