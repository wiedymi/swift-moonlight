import Foundation

public struct RTSPSessionPlan: Sendable, Equatable {
    public var optionsRequest: RTSPRequest
    public var describeRequest: RTSPRequest
    public var audioSetupRequest: RTSPRequest
    public var videoSetupRequest: RTSPRequest
    public var controlSetupRequest: RTSPRequest?
    public var announceRequest: RTSPRequest
    public var playRequests: [RTSPRequest]

    public init(
        optionsRequest: RTSPRequest,
        describeRequest: RTSPRequest,
        audioSetupRequest: RTSPRequest,
        videoSetupRequest: RTSPRequest,
        controlSetupRequest: RTSPRequest?,
        announceRequest: RTSPRequest,
        playRequests: [RTSPRequest]
    ) {
        self.optionsRequest = optionsRequest
        self.describeRequest = describeRequest
        self.audioSetupRequest = audioSetupRequest
        self.videoSetupRequest = videoSetupRequest
        self.controlSetupRequest = controlSetupRequest
        self.announceRequest = announceRequest
        self.playRequests = playRequests
    }
}

public struct RTSPRequestPlanBuilder: Sendable {
    public let factory: RTSPRequestFactory

    public init(factory: RTSPRequestFactory = RTSPRequestFactory()) {
        self.factory = factory
    }

    public func buildPlan(
        sessionURL: String,
        sessionID: String,
        sdp: Data,
        useUnifiedPlay: Bool = true,
        includeControlStream: Bool = true
    ) -> RTSPSessionPlan {
        var cSeq = 1
        let options = factory.options(url: sessionURL, cSeq: cSeq)
        cSeq += 1
        let describe = factory.describe(url: sessionURL, cSeq: cSeq)
        cSeq += 1
        let audioSetup = factory.setup(target: "streamid=audio/0/0", sessionURL: sessionURL, cSeq: cSeq, sessionID: nil)
        cSeq += 1
        let videoSetup = factory.setup(target: "streamid=video/0/0", sessionURL: sessionURL, cSeq: cSeq, sessionID: sessionID)
        cSeq += 1

        let controlSetup: RTSPRequest?
        if includeControlStream {
            controlSetup = factory.setup(target: "streamid=control/13/0", sessionURL: sessionURL, cSeq: cSeq, sessionID: sessionID)
            cSeq += 1
        } else {
            controlSetup = nil
        }

        let announce = factory.announce(target: "streamid=control/13/0", sessionURL: sessionURL, cSeq: cSeq, sessionID: sessionID, sdp: sdp)
        cSeq += 1

        let playRequests: [RTSPRequest]
        if useUnifiedPlay {
            playRequests = [factory.play(target: "/", sessionURL: sessionURL, cSeq: cSeq, sessionID: sessionID)]
        } else {
            playRequests = [
                factory.play(target: "streamid=video", sessionURL: sessionURL, cSeq: cSeq, sessionID: sessionID),
                factory.play(target: "streamid=audio", sessionURL: sessionURL, cSeq: cSeq + 1, sessionID: sessionID),
            ]
        }

        return RTSPSessionPlan(
            optionsRequest: options,
            describeRequest: describe,
            audioSetupRequest: audioSetup,
            videoSetupRequest: videoSetup,
            controlSetupRequest: controlSetup,
            announceRequest: announce,
            playRequests: playRequests
        )
    }
}
