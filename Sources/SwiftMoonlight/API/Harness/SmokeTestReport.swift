import Foundation

public struct SmokeRestartObservation: Sendable, Equatable, Codable {
    public var index: Int
    public var launchAccepted: Bool
    public var controlConnected: Bool
    public var inputConnected: Bool
    public var controlRoundTripTimeMs: Int?
    public var controlPacketLossRatio: Double?
    public var videoPacketsObserved: Int
    public var audioPacketsObserved: Int
    public var missingVideoPackets: Int
    public var reorderedVideoPackets: Int
    public var videoDiscontinuityEvents: Int
    public var videoFrameFECStatusReports: Int
    public var decodedVideoFrames: Int
    public var renderedVideoFrames: Int
    public var unexpectedDisconnect: Bool

    public init(
        index: Int,
        launchAccepted: Bool = false,
        controlConnected: Bool = false,
        inputConnected: Bool = false,
        controlRoundTripTimeMs: Int? = nil,
        controlPacketLossRatio: Double? = nil,
        videoPacketsObserved: Int = 0,
        audioPacketsObserved: Int = 0,
        missingVideoPackets: Int = 0,
        reorderedVideoPackets: Int = 0,
        videoDiscontinuityEvents: Int = 0,
        videoFrameFECStatusReports: Int = 0,
        decodedVideoFrames: Int = 0,
        renderedVideoFrames: Int = 0,
        unexpectedDisconnect: Bool = false
    ) {
        self.index = index
        self.launchAccepted = launchAccepted
        self.controlConnected = controlConnected
        self.inputConnected = inputConnected
        self.controlRoundTripTimeMs = controlRoundTripTimeMs
        self.controlPacketLossRatio = controlPacketLossRatio
        self.videoPacketsObserved = videoPacketsObserved
        self.audioPacketsObserved = audioPacketsObserved
        self.missingVideoPackets = missingVideoPackets
        self.reorderedVideoPackets = reorderedVideoPackets
        self.videoDiscontinuityEvents = videoDiscontinuityEvents
        self.videoFrameFECStatusReports = videoFrameFECStatusReports
        self.decodedVideoFrames = decodedVideoFrames
        self.renderedVideoFrames = renderedVideoFrames
        self.unexpectedDisconnect = unexpectedDisconnect
    }
}

public struct SmokeTestReport: Sendable, Equatable, Codable {
    public var paired: Bool
    public var appsFetched: Bool
    public var preLaunchCancelAttempted: Bool
    public var launchAccepted: Bool
    public var controlConnected: Bool
    public var inputConnected: Bool
    public var controlRoundTripTimeMs: Int?
    public var controlRoundTripTimeVarianceMs: Int?
    public var controlPacketLossRatio: Double?
    public var controlPacketLossVarianceRatio: Double?
    public var videoPacketsObserved: Int
    public var audioPacketsObserved: Int
    public var missingVideoPackets: Int
    public var reorderedVideoPackets: Int
    public var videoDiscontinuityEvents: Int
    public var videoFrameFECStatusReports: Int
    public var decodedVideoFrames: Int
    public var renderedVideoFrames: Int
    public var inputPacketsSent: Int
    public var averageInputQueueLatencyMs: Double?
    public var maxInputQueueLatencyMs: Double?
    public var averageInputTransportLatencyMs: Double?
    public var maxInputTransportLatencyMs: Double?
    public var inputProbeSucceeded: Bool
    public var inputProbeMode: InputProbeMode
    public var inputProbeRepeatCount: Int
    public var maxInputLatencyMs: Double?
    public var maxMissingVideoPackets: Int?
    public var maxVideoDiscontinuities: Int?
    public var videoPacketTrace: [VideoPacketTraceEntry]
    public var audioExpected: Bool
    public var unexpectedDisconnect: Bool
    public var restartAttempted: Bool
    public var restartLaunchAccepted: Bool
    public var restartControlConnected: Bool
    public var restartInputConnected: Bool
    public var restartVideoPacketsObserved: Int
    public var restartAudioPacketsObserved: Int
    public var restartDecodedVideoFrames: Int
    public var restartRenderedVideoFrames: Int
    public var restartUnexpectedDisconnect: Bool
    public var restartCountRequested: Int
    public var restartObservations: [SmokeRestartObservation]

    public init(
        paired: Bool = false,
        appsFetched: Bool = false,
        preLaunchCancelAttempted: Bool = false,
        launchAccepted: Bool = false,
        controlConnected: Bool = false,
        inputConnected: Bool = false,
        controlRoundTripTimeMs: Int? = nil,
        controlRoundTripTimeVarianceMs: Int? = nil,
        controlPacketLossRatio: Double? = nil,
        controlPacketLossVarianceRatio: Double? = nil,
        videoPacketsObserved: Int = 0,
        audioPacketsObserved: Int = 0,
        missingVideoPackets: Int = 0,
        reorderedVideoPackets: Int = 0,
        videoDiscontinuityEvents: Int = 0,
        videoFrameFECStatusReports: Int = 0,
        decodedVideoFrames: Int = 0,
        renderedVideoFrames: Int = 0,
        inputPacketsSent: Int = 0,
        averageInputQueueLatencyMs: Double? = nil,
        maxInputQueueLatencyMs: Double? = nil,
        averageInputTransportLatencyMs: Double? = nil,
        maxInputTransportLatencyMs: Double? = nil,
        inputProbeSucceeded: Bool = false,
        inputProbeMode: InputProbeMode = .noop,
        inputProbeRepeatCount: Int = 1,
        maxInputLatencyMs: Double? = nil,
        maxMissingVideoPackets: Int? = nil,
        maxVideoDiscontinuities: Int? = nil,
        videoPacketTrace: [VideoPacketTraceEntry] = [],
        audioExpected: Bool = true,
        unexpectedDisconnect: Bool = false,
        restartAttempted: Bool = false,
        restartLaunchAccepted: Bool = false,
        restartControlConnected: Bool = false,
        restartInputConnected: Bool = false,
        restartVideoPacketsObserved: Int = 0,
        restartAudioPacketsObserved: Int = 0,
        restartDecodedVideoFrames: Int = 0,
        restartRenderedVideoFrames: Int = 0,
        restartUnexpectedDisconnect: Bool = false,
        restartCountRequested: Int = 0,
        restartObservations: [SmokeRestartObservation] = []
    ) {
        self.paired = paired
        self.appsFetched = appsFetched
        self.preLaunchCancelAttempted = preLaunchCancelAttempted
        self.launchAccepted = launchAccepted
        self.controlConnected = controlConnected
        self.inputConnected = inputConnected
        self.controlRoundTripTimeMs = controlRoundTripTimeMs
        self.controlRoundTripTimeVarianceMs = controlRoundTripTimeVarianceMs
        self.controlPacketLossRatio = controlPacketLossRatio
        self.controlPacketLossVarianceRatio = controlPacketLossVarianceRatio
        self.videoPacketsObserved = videoPacketsObserved
        self.audioPacketsObserved = audioPacketsObserved
        self.missingVideoPackets = missingVideoPackets
        self.reorderedVideoPackets = reorderedVideoPackets
        self.videoDiscontinuityEvents = videoDiscontinuityEvents
        self.videoFrameFECStatusReports = videoFrameFECStatusReports
        self.decodedVideoFrames = decodedVideoFrames
        self.renderedVideoFrames = renderedVideoFrames
        self.inputPacketsSent = inputPacketsSent
        self.averageInputQueueLatencyMs = averageInputQueueLatencyMs
        self.maxInputQueueLatencyMs = maxInputQueueLatencyMs
        self.averageInputTransportLatencyMs = averageInputTransportLatencyMs
        self.maxInputTransportLatencyMs = maxInputTransportLatencyMs
        self.inputProbeSucceeded = inputProbeSucceeded
        self.inputProbeMode = inputProbeMode
        self.inputProbeRepeatCount = max(1, inputProbeRepeatCount)
        self.maxInputLatencyMs = maxInputLatencyMs
        self.maxMissingVideoPackets = maxMissingVideoPackets
        self.maxVideoDiscontinuities = maxVideoDiscontinuities
        self.videoPacketTrace = videoPacketTrace
        self.audioExpected = audioExpected
        self.unexpectedDisconnect = unexpectedDisconnect
        self.restartAttempted = restartAttempted
        self.restartLaunchAccepted = restartLaunchAccepted
        self.restartControlConnected = restartControlConnected
        self.restartInputConnected = restartInputConnected
        self.restartVideoPacketsObserved = restartVideoPacketsObserved
        self.restartAudioPacketsObserved = restartAudioPacketsObserved
        self.restartDecodedVideoFrames = restartDecodedVideoFrames
        self.restartRenderedVideoFrames = restartRenderedVideoFrames
        self.restartUnexpectedDisconnect = restartUnexpectedDisconnect
        self.restartCountRequested = restartCountRequested
        self.restartObservations = restartObservations
    }

    public func failures(requireVideoPackets: Bool = true) -> [String] {
        var failures: [String] = []
        if !paired { failures.append("pairing did not complete") }
        if !appsFetched { failures.append("app list fetch returned no apps") }
        if !launchAccepted { failures.append("launch was not accepted") }
        if !controlConnected { failures.append("control channel was not established") }
        if !inputConnected { failures.append("input channel was not established") }
        if inputConnected, inputProbeMode != .disabled, !inputProbeSucceeded {
            failures.append("input probe did not complete")
        }
        if let maxInputLatencyMs {
            if let maxInputQueueLatencyMs, maxInputQueueLatencyMs > maxInputLatencyMs {
                failures.append("input queue latency exceeded \(maxInputLatencyMs) ms")
            }
            if let maxInputTransportLatencyMs, maxInputTransportLatencyMs > maxInputLatencyMs {
                failures.append("input transport latency exceeded \(maxInputLatencyMs) ms")
            }
        }
        if requireVideoPackets, videoPacketsObserved == 0 {
            failures.append("video channel observed no packets")
        }
        appendVideoQualityFailures(
            to: &failures,
            prefix: nil,
            missingVideoPackets: missingVideoPackets,
            videoDiscontinuityEvents: videoDiscontinuityEvents
        )
        if audioExpected, audioPacketsObserved == 0 {
            failures.append("audio channel observed no packets")
        }
        if unexpectedDisconnect {
            failures.append("session disconnected unexpectedly")
        }
        if restartAttempted {
            if restartObservations.isEmpty {
                appendRestartFailures(
                    to: &failures,
                    prefix: "restart",
                    launchAccepted: restartLaunchAccepted,
                    controlConnected: restartControlConnected,
                    inputConnected: restartInputConnected,
                    videoPacketsObserved: restartVideoPacketsObserved,
                    audioPacketsObserved: restartAudioPacketsObserved,
                    missingVideoPackets: 0,
                    videoDiscontinuityEvents: 0,
                    unexpectedDisconnect: restartUnexpectedDisconnect,
                    requireVideoPackets: requireVideoPackets
                )
            } else {
                let useIndexedPrefix = restartObservations.count > 1 || restartCountRequested > 1
                for observation in restartObservations {
                    appendRestartFailures(
                        to: &failures,
                        prefix: useIndexedPrefix ? "restart #\(observation.index)" : "restart",
                        launchAccepted: observation.launchAccepted,
                        controlConnected: observation.controlConnected,
                        inputConnected: observation.inputConnected,
                        videoPacketsObserved: observation.videoPacketsObserved,
                        audioPacketsObserved: observation.audioPacketsObserved,
                        missingVideoPackets: observation.missingVideoPackets,
                        videoDiscontinuityEvents: observation.videoDiscontinuityEvents,
                        unexpectedDisconnect: observation.unexpectedDisconnect,
                        requireVideoPackets: requireVideoPackets
                    )
                }
            }
            if restartCountRequested > 0, restartObservations.count < restartCountRequested {
                failures.append("restart soak stopped after \(restartObservations.count) of \(restartCountRequested) attempt(s)")
            }
        }
        return failures
    }

    public var passed: Bool {
        failures().isEmpty
    }

    private func appendRestartFailures(
        to failures: inout [String],
        prefix: String,
        launchAccepted: Bool,
        controlConnected: Bool,
        inputConnected: Bool,
        videoPacketsObserved: Int,
        audioPacketsObserved: Int,
        missingVideoPackets: Int,
        videoDiscontinuityEvents: Int,
        unexpectedDisconnect: Bool,
        requireVideoPackets: Bool
    ) {
        if !launchAccepted { failures.append("\(prefix) launch was not accepted") }
        if !controlConnected { failures.append("\(prefix) control channel was not established") }
        if !inputConnected { failures.append("\(prefix) input channel was not established") }
        if requireVideoPackets, videoPacketsObserved == 0 {
            failures.append("\(prefix) video channel observed no packets")
        }
        appendVideoQualityFailures(
            to: &failures,
            prefix: prefix,
            missingVideoPackets: missingVideoPackets,
            videoDiscontinuityEvents: videoDiscontinuityEvents
        )
        if audioExpected, audioPacketsObserved == 0 {
            failures.append("\(prefix) audio channel observed no packets")
        }
        if unexpectedDisconnect {
            failures.append("\(prefix) session disconnected unexpectedly")
        }
    }

    private func appendVideoQualityFailures(
        to failures: inout [String],
        prefix: String?,
        missingVideoPackets: Int,
        videoDiscontinuityEvents: Int
    ) {
        let messagePrefix = prefix.map { "\($0) " } ?? ""
        if let maxMissingVideoPackets, missingVideoPackets > maxMissingVideoPackets {
            failures.append("\(messagePrefix)missing video packets exceeded \(maxMissingVideoPackets): \(missingVideoPackets)")
        }
        if let maxVideoDiscontinuities, videoDiscontinuityEvents > maxVideoDiscontinuities {
            failures.append("\(messagePrefix)video discontinuities exceeded \(maxVideoDiscontinuities): \(videoDiscontinuityEvents)")
        }
    }
}

struct SmokeSessionObservation: Sendable {
    var controlConnected: Bool
    var inputConnected: Bool
    var controlRoundTripTimeMs: Int?
    var controlRoundTripTimeVarianceMs: Int?
    var controlPacketLossRatio: Double?
    var controlPacketLossVarianceRatio: Double?
    var videoPacketsObserved: Int
    var audioPacketsObserved: Int
    var missingVideoPackets: Int
    var reorderedVideoPackets: Int
    var videoDiscontinuityEvents: Int
    var videoFrameFECStatusReports: Int
    var decodedVideoFrames: Int
    var renderedVideoFrames: Int
    var inputPacketsSent: Int
    var averageInputQueueLatencyMs: Double?
    var maxInputQueueLatencyMs: Double?
    var averageInputTransportLatencyMs: Double?
    var maxInputTransportLatencyMs: Double?
    var inputProbeSucceeded: Bool
    var videoPacketTrace: [VideoPacketTraceEntry]
    var unexpectedDisconnect: Bool
}

extension SmokeRestartObservation {
    init(index: Int, observation: SmokeSessionObservation) {
        self.init(
            index: index,
            launchAccepted: true,
            controlConnected: observation.controlConnected,
            inputConnected: observation.inputConnected,
            controlRoundTripTimeMs: observation.controlRoundTripTimeMs,
            controlPacketLossRatio: observation.controlPacketLossRatio,
            videoPacketsObserved: observation.videoPacketsObserved,
            audioPacketsObserved: observation.audioPacketsObserved,
            missingVideoPackets: observation.missingVideoPackets,
            reorderedVideoPackets: observation.reorderedVideoPackets,
            videoDiscontinuityEvents: observation.videoDiscontinuityEvents,
            videoFrameFECStatusReports: observation.videoFrameFECStatusReports,
            decodedVideoFrames: observation.decodedVideoFrames,
            renderedVideoFrames: observation.renderedVideoFrames,
            unexpectedDisconnect: observation.unexpectedDisconnect
        )
    }
}
