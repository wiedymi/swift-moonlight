import CoreGraphics
import Foundation

public struct SessionMetricsSnapshot: Equatable, Sendable, Codable {
    public var sessionOpenDurationMs: Int?
    public var controlRoundTripTimeMs: Int?
    public var controlRoundTripTimeVarianceMs: Int?
    public var controlPacketLossRatio: Double?
    public var controlPacketLossVarianceRatio: Double?
    public var inputEventsSent: Int
    public var inputPacketsSent: Int
    public var rendererAttachments: Int
    public var audioSinkAttachments: Int
    public var establishedChannelCount: Int
    public var controlMessagesObserved: Int
    public var videoPacketsObserved: Int
    public var audioPacketsObserved: Int
    public var audioConcealmentPackets: Int
    public var missingVideoPackets: Int
    public var missingAudioPackets: Int
    public var reorderedVideoPackets: Int
    public var reorderedAudioPackets: Int
    public var videoDiscontinuityEvents: Int
    public var videoFrameFECStatusReports: Int
    public var recoverableVideoDecodeFailures: Int
    public var reconnectAttempts: Int
    public var decodedVideoFrames: Int
    public var renderedVideoFrames: Int
    public var decodedAudioBuffers: Int
    public var playedAudioBuffers: Int
    public var averageVideoDecodeLatencyMs: Double?
    public var maxVideoDecodeLatencyMs: Double?
    public var averageVideoQueueLatencyMs: Double?
    public var maxVideoQueueLatencyMs: Double?
    public var averageVideoRenderSubmissionLatencyMs: Double?
    public var maxVideoRenderSubmissionLatencyMs: Double?
    public var averageHostProcessingLatencyMs: Double?
    public var maxHostProcessingLatencyMs: Double?
    public var averageAudioDecodeLatencyMs: Double?
    public var maxAudioDecodeLatencyMs: Double?
    public var averageInputQueueLatencyMs: Double?
    public var maxInputQueueLatencyMs: Double?
    public var averageInputTransportLatencyMs: Double?
    public var maxInputTransportLatencyMs: Double?
    public var audioUnderrunEvents: Int
    public var unexpectedDisconnect: Bool

    public init(
        sessionOpenDurationMs: Int? = nil,
        controlRoundTripTimeMs: Int? = nil,
        controlRoundTripTimeVarianceMs: Int? = nil,
        controlPacketLossRatio: Double? = nil,
        controlPacketLossVarianceRatio: Double? = nil,
        inputEventsSent: Int = 0,
        inputPacketsSent: Int = 0,
        rendererAttachments: Int = 0,
        audioSinkAttachments: Int = 0,
        establishedChannelCount: Int = 0,
        controlMessagesObserved: Int = 0,
        videoPacketsObserved: Int = 0,
        audioPacketsObserved: Int = 0,
        audioConcealmentPackets: Int = 0,
        missingVideoPackets: Int = 0,
        missingAudioPackets: Int = 0,
        reorderedVideoPackets: Int = 0,
        reorderedAudioPackets: Int = 0,
        videoDiscontinuityEvents: Int = 0,
        videoFrameFECStatusReports: Int = 0,
        recoverableVideoDecodeFailures: Int = 0,
        reconnectAttempts: Int = 0,
        decodedVideoFrames: Int = 0,
        renderedVideoFrames: Int = 0,
        decodedAudioBuffers: Int = 0,
        playedAudioBuffers: Int = 0,
        averageVideoDecodeLatencyMs: Double? = nil,
        maxVideoDecodeLatencyMs: Double? = nil,
        averageVideoQueueLatencyMs: Double? = nil,
        maxVideoQueueLatencyMs: Double? = nil,
        averageVideoRenderSubmissionLatencyMs: Double? = nil,
        maxVideoRenderSubmissionLatencyMs: Double? = nil,
        averageHostProcessingLatencyMs: Double? = nil,
        maxHostProcessingLatencyMs: Double? = nil,
        averageAudioDecodeLatencyMs: Double? = nil,
        maxAudioDecodeLatencyMs: Double? = nil,
        averageInputQueueLatencyMs: Double? = nil,
        maxInputQueueLatencyMs: Double? = nil,
        averageInputTransportLatencyMs: Double? = nil,
        maxInputTransportLatencyMs: Double? = nil,
        audioUnderrunEvents: Int = 0,
        unexpectedDisconnect: Bool = false
    ) {
        self.sessionOpenDurationMs = sessionOpenDurationMs
        self.controlRoundTripTimeMs = controlRoundTripTimeMs
        self.controlRoundTripTimeVarianceMs = controlRoundTripTimeVarianceMs
        self.controlPacketLossRatio = controlPacketLossRatio
        self.controlPacketLossVarianceRatio = controlPacketLossVarianceRatio
        self.inputEventsSent = inputEventsSent
        self.inputPacketsSent = inputPacketsSent
        self.rendererAttachments = rendererAttachments
        self.audioSinkAttachments = audioSinkAttachments
        self.establishedChannelCount = establishedChannelCount
        self.controlMessagesObserved = controlMessagesObserved
        self.videoPacketsObserved = videoPacketsObserved
        self.audioPacketsObserved = audioPacketsObserved
        self.audioConcealmentPackets = audioConcealmentPackets
        self.missingVideoPackets = missingVideoPackets
        self.missingAudioPackets = missingAudioPackets
        self.reorderedVideoPackets = reorderedVideoPackets
        self.reorderedAudioPackets = reorderedAudioPackets
        self.videoDiscontinuityEvents = videoDiscontinuityEvents
        self.videoFrameFECStatusReports = videoFrameFECStatusReports
        self.recoverableVideoDecodeFailures = recoverableVideoDecodeFailures
        self.reconnectAttempts = reconnectAttempts
        self.decodedVideoFrames = decodedVideoFrames
        self.renderedVideoFrames = renderedVideoFrames
        self.decodedAudioBuffers = decodedAudioBuffers
        self.playedAudioBuffers = playedAudioBuffers
        self.averageVideoDecodeLatencyMs = averageVideoDecodeLatencyMs
        self.maxVideoDecodeLatencyMs = maxVideoDecodeLatencyMs
        self.averageVideoQueueLatencyMs = averageVideoQueueLatencyMs
        self.maxVideoQueueLatencyMs = maxVideoQueueLatencyMs
        self.averageVideoRenderSubmissionLatencyMs = averageVideoRenderSubmissionLatencyMs
        self.maxVideoRenderSubmissionLatencyMs = maxVideoRenderSubmissionLatencyMs
        self.averageHostProcessingLatencyMs = averageHostProcessingLatencyMs
        self.maxHostProcessingLatencyMs = maxHostProcessingLatencyMs
        self.averageAudioDecodeLatencyMs = averageAudioDecodeLatencyMs
        self.maxAudioDecodeLatencyMs = maxAudioDecodeLatencyMs
        self.averageInputQueueLatencyMs = averageInputQueueLatencyMs
        self.maxInputQueueLatencyMs = maxInputQueueLatencyMs
        self.averageInputTransportLatencyMs = averageInputTransportLatencyMs
        self.maxInputTransportLatencyMs = maxInputTransportLatencyMs
        self.audioUnderrunEvents = audioUnderrunEvents
        self.unexpectedDisconnect = unexpectedDisconnect
    }
}

public struct MoonlightWarning: Sendable, Equatable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }
}
