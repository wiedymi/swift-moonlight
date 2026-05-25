import Foundation

public struct RTSPNegotiationResult: Sendable, Equatable {
    public var sessionID: String
    public var audio: RTSPSessionInfo
    public var video: RTSPSessionInfo
    public var control: RTSPSessionInfo?
    public var describeInfo: RTSPDescribeInfo

    public init(
        sessionID: String,
        audio: RTSPSessionInfo,
        video: RTSPSessionInfo,
        control: RTSPSessionInfo?,
        describeInfo: RTSPDescribeInfo = .init()
    ) {
        self.sessionID = sessionID
        self.audio = audio
        self.video = video
        self.control = control
        self.describeInfo = describeInfo
    }
}

public struct RTSPNegotiationService: Sendable {
    public let transport: any RTSPTransport
    public let planBuilder: RTSPRequestPlanBuilder
    public let sessionInfoParser: RTSPSessionInfoParser
    public let describeInfoParser: RTSPDescribeInfoParser
    public let requestFactory: RTSPRequestFactory

    public init(
        transport: any RTSPTransport,
        planBuilder: RTSPRequestPlanBuilder = RTSPRequestPlanBuilder(),
        sessionInfoParser: RTSPSessionInfoParser = RTSPSessionInfoParser(),
        describeInfoParser: RTSPDescribeInfoParser = RTSPDescribeInfoParser(),
        requestFactory: RTSPRequestFactory = RTSPRequestFactory()
    ) {
        self.transport = transport
        self.planBuilder = planBuilder
        self.sessionInfoParser = sessionInfoParser
        self.describeInfoParser = describeInfoParser
        self.requestFactory = requestFactory
    }

    public func negotiate(
        sessionURL: String,
        sdp: Data = Data("v=0\r\n".utf8),
        remoteInputKey: Data? = nil,
        useUnifiedPlay: Bool = true,
        includeControlStream: Bool = true,
        afterAudioSetup: (@Sendable (RTSPSessionInfo, RTSPDescribeInfo) async throws -> Void)? = nil,
        prePlay: (@Sendable (RTSPNegotiationResult) async throws -> Void)? = nil
    ) async throws -> RTSPNegotiationResult {
        try await negotiate(
            sessionURL: sessionURL,
            sdpBuilder: { _ in sdp },
            remoteInputKey: remoteInputKey,
            useUnifiedPlay: useUnifiedPlay,
            includeControlStream: includeControlStream,
            afterAudioSetup: afterAudioSetup,
            prePlay: prePlay
        )
    }

    public func negotiate(
        sessionURL: String,
        sdpBuilder: @Sendable (RTSPDescribeInfo) -> Data,
        remoteInputKey: Data? = nil,
        useUnifiedPlay: Bool = true,
        includeControlStream: Bool = true,
        afterAudioSetup: (@Sendable (RTSPSessionInfo, RTSPDescribeInfo) async throws -> Void)? = nil,
        prePlay: (@Sendable (RTSPNegotiationResult) async throws -> Void)? = nil
    ) async throws -> RTSPNegotiationResult {
        let optionsResponse = try await transport.transact(
            sessionURL: sessionURL,
            request: requestFactory.options(url: sessionURL, cSeq: 1),
            encryptionKey: remoteInputKey
        )
        guard optionsResponse.statusCode == 200 else {
            throw MoonlightError(.unsupportedOperation, message: "RTSP OPTIONS failed with status \(optionsResponse.statusCode)")
        }

        let describeResponse = try await transport.transact(
            sessionURL: sessionURL,
            request: requestFactory.describe(url: sessionURL, cSeq: 2),
            encryptionKey: remoteInputKey
        )
        guard describeResponse.statusCode == 200 else {
            throw MoonlightError(.unsupportedOperation, message: "RTSP DESCRIBE failed with status \(describeResponse.statusCode)")
        }
        let describeInfo = describeInfoParser.parseDescribeResponse(describeResponse)

        let initialAudioSetup = try await transport.transact(
            sessionURL: sessionURL,
            request: requestFactory.setup(target: "streamid=audio/0/0", sessionURL: sessionURL, cSeq: 3, sessionID: nil),
            encryptionKey: remoteInputKey
        )
        guard initialAudioSetup.statusCode == 200 else {
            throw MoonlightError(.unsupportedOperation, message: "RTSP audio SETUP failed with status \(initialAudioSetup.statusCode)")
        }

        let audioInfo = sessionInfoParser.parseSetupResponse(initialAudioSetup)
        guard let sessionID = audioInfo.sessionID else {
            throw MoonlightError(.unsupportedOperation, message: "RTSP audio SETUP response is missing Session header")
        }
        try await afterAudioSetup?(audioInfo, describeInfo)

        let sdp = sdpBuilder(describeInfo)
        let plan = planBuilder.buildPlan(
            sessionURL: sessionURL,
            sessionID: sessionID,
            sdp: sdp,
            useUnifiedPlay: useUnifiedPlay,
            includeControlStream: includeControlStream
        )

        let videoResponse = try await transport.transact(
            sessionURL: sessionURL,
            request: plan.videoSetupRequest,
            encryptionKey: remoteInputKey
        )
        guard videoResponse.statusCode == 200 else {
            throw MoonlightError(.unsupportedOperation, message: "RTSP video SETUP failed with status \(videoResponse.statusCode)")
        }
        let videoInfo = sessionInfoParser.parseSetupResponse(videoResponse)

        let controlInfo: RTSPSessionInfo?
        if let controlRequest = plan.controlSetupRequest {
            let controlResponse = try await transport.transact(
                sessionURL: sessionURL,
                request: controlRequest,
                encryptionKey: remoteInputKey
            )
            guard controlResponse.statusCode == 200 else {
                throw MoonlightError(.unsupportedOperation, message: "RTSP control SETUP failed with status \(controlResponse.statusCode)")
            }
            controlInfo = sessionInfoParser.parseSetupResponse(controlResponse)
        } else {
            controlInfo = nil
        }

        let negotiationResult = RTSPNegotiationResult(
            sessionID: sessionID,
            audio: audioInfo,
            video: videoInfo,
            control: controlInfo,
            describeInfo: describeInfo
        )

        try await prePlay?(negotiationResult)

        let announceResponse = try await transport.transact(
            sessionURL: sessionURL,
            request: plan.announceRequest,
            encryptionKey: remoteInputKey
        )
        guard announceResponse.statusCode == 200 else {
            throw MoonlightError(.unsupportedOperation, message: "RTSP ANNOUNCE failed with status \(announceResponse.statusCode)")
        }

        for playRequest in plan.playRequests {
            let playResponse = try await transport.transact(
                sessionURL: sessionURL,
                request: playRequest,
                encryptionKey: remoteInputKey
            )
            guard playResponse.statusCode == 200 else {
                throw MoonlightError(.unsupportedOperation, message: "RTSP PLAY failed with status \(playResponse.statusCode)")
            }
        }

        return negotiationResult
    }
}
