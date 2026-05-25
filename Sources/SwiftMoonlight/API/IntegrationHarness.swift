import Foundation

public enum InputProbeMode: String, Sendable, Equatable, Codable {
    case disabled
    case noop
    case reversibleRelativeMotion
    case absolutePointerSweep
}

public struct IntegrationHarnessConfiguration: Sendable {
    public var endpoint: HostEndpoint
    public var pairingAuthProvider: @Sendable () async throws -> PairingAuth
    public var appID: String
    public var streamConfiguration: StreamConfiguration
    public var observationWindow: Duration
    public var runtimeConfiguration: StreamRuntimeConfiguration
    public var requireAudioPackets: Bool
    public var inputProbeMode: InputProbeMode
    public var inputProbeRepeatCount: Int
    public var maxInputLatencyMs: Double?
    public var maxMissingVideoPackets: Int?
    public var maxVideoDiscontinuities: Int?
    public var restartStreamConfiguration: StreamConfiguration?
    public var restartCount: Int
    public var cancelCurrentAppBeforeLaunch: Bool

    public init(
        endpoint: HostEndpoint,
        pinProvider: @escaping @Sendable () async throws -> String,
        appID: String,
        streamConfiguration: StreamConfiguration,
        observationWindow: Duration,
        runtimeConfiguration: StreamRuntimeConfiguration = .init(),
        requireAudioPackets: Bool = true,
        inputProbeMode: InputProbeMode = .noop,
        inputProbeRepeatCount: Int = 1,
        maxInputLatencyMs: Double? = nil,
        maxMissingVideoPackets: Int? = nil,
        maxVideoDiscontinuities: Int? = nil,
        restartStreamConfiguration: StreamConfiguration? = nil,
        restartCount: Int = 1,
        cancelCurrentAppBeforeLaunch: Bool = false
    ) {
        self.init(
            endpoint: endpoint,
            pairingAuthProvider: {
                .pin(try await pinProvider())
            },
            appID: appID,
            streamConfiguration: streamConfiguration,
            observationWindow: observationWindow,
            runtimeConfiguration: runtimeConfiguration,
            requireAudioPackets: requireAudioPackets,
            inputProbeMode: inputProbeMode,
            inputProbeRepeatCount: inputProbeRepeatCount,
            maxInputLatencyMs: maxInputLatencyMs,
            maxMissingVideoPackets: maxMissingVideoPackets,
            maxVideoDiscontinuities: maxVideoDiscontinuities,
            restartStreamConfiguration: restartStreamConfiguration,
            restartCount: restartCount,
            cancelCurrentAppBeforeLaunch: cancelCurrentAppBeforeLaunch
        )
    }

    public init(
        endpoint: HostEndpoint,
        pairingAuthProvider: @escaping @Sendable () async throws -> PairingAuth,
        appID: String,
        streamConfiguration: StreamConfiguration,
        observationWindow: Duration,
        runtimeConfiguration: StreamRuntimeConfiguration = .init(),
        requireAudioPackets: Bool = true,
        inputProbeMode: InputProbeMode = .noop,
        inputProbeRepeatCount: Int = 1,
        maxInputLatencyMs: Double? = nil,
        maxMissingVideoPackets: Int? = nil,
        maxVideoDiscontinuities: Int? = nil,
        restartStreamConfiguration: StreamConfiguration? = nil,
        restartCount: Int = 1,
        cancelCurrentAppBeforeLaunch: Bool = false
    ) {
        self.endpoint = endpoint
        self.pairingAuthProvider = pairingAuthProvider
        self.appID = appID
        self.streamConfiguration = streamConfiguration
        self.observationWindow = observationWindow
        self.runtimeConfiguration = runtimeConfiguration
        self.requireAudioPackets = requireAudioPackets
        self.inputProbeMode = inputProbeMode
        self.inputProbeRepeatCount = max(1, inputProbeRepeatCount)
        self.maxInputLatencyMs = maxInputLatencyMs
        self.maxMissingVideoPackets = maxMissingVideoPackets
        self.maxVideoDiscontinuities = maxVideoDiscontinuities
        self.restartStreamConfiguration = restartStreamConfiguration
        self.restartCount = max(1, restartCount)
        self.cancelCurrentAppBeforeLaunch = cancelCurrentAppBeforeLaunch
    }

    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        defaultPort: Int = 47989,
        defaultAppID: String = "desktop",
        defaultStreamConfiguration: StreamConfiguration = .default1080p60,
        defaultObservationWindow: Duration = .seconds(30),
        defaultRuntimeConfiguration: StreamRuntimeConfiguration = .init()
    ) throws -> IntegrationHarnessConfiguration {
        guard let hostValue = environment["SWIFT_MOONLIGHT_TEST_HOST"], !hostValue.isEmpty else {
            throw MoonlightError(.unsupportedOperation, message: "Missing SWIFT_MOONLIGHT_TEST_HOST")
        }

        let endpoint = try parseEndpoint(hostValue, defaultPort: defaultPort)
        let pin = environment["SWIFT_MOONLIGHT_TEST_PIN"] ?? "1234"
        let otpPassphrase = environment["SWIFT_MOONLIGHT_TEST_PASSPHRASE"]
        let appID = environment["SWIFT_MOONLIGHT_TEST_APP_ID"] ?? defaultAppID
        var runtimeConfiguration = defaultRuntimeConfiguration
        if let videoPacketTraceLimit = try parseNonNegativeInt(
            environment["SWIFT_MOONLIGHT_TEST_VIDEO_PACKET_TRACE_LIMIT"],
            variableName: "SWIFT_MOONLIGHT_TEST_VIDEO_PACKET_TRACE_LIMIT"
        ) {
            runtimeConfiguration.videoPacketTraceLimit = videoPacketTraceLimit
        }

        var streamConfiguration = defaultStreamConfiguration
        if let resolution = try parseResolution(
            environment["SWIFT_MOONLIGHT_TEST_RESOLUTION"],
            variableName: "SWIFT_MOONLIGHT_TEST_RESOLUTION"
        ) {
            streamConfiguration.resolution = resolution
        }
        if let frameRate = try parsePositiveIntOptional(
            environment["SWIFT_MOONLIGHT_TEST_FPS"],
            variableName: "SWIFT_MOONLIGHT_TEST_FPS"
        ) {
            streamConfiguration.frameRate = frameRate
        }
        if let bitrateKbps = try parsePositiveIntOptional(
            environment["SWIFT_MOONLIGHT_TEST_BITRATE_KBPS"],
            variableName: "SWIFT_MOONLIGHT_TEST_BITRATE_KBPS"
        ) {
            streamConfiguration.bitrateKbps = bitrateKbps
        }
        if let dynamicRange = try parseDynamicRange(
            environment["SWIFT_MOONLIGHT_TEST_DYNAMIC_RANGE"],
            variableName: "SWIFT_MOONLIGHT_TEST_DYNAMIC_RANGE"
        ) {
            streamConfiguration.dynamicRange = dynamicRange
        }
        if let codecs = try parseCodecs(
            environment["SWIFT_MOONLIGHT_TEST_CODECS"],
            variableName: "SWIFT_MOONLIGHT_TEST_CODECS"
        ) {
            streamConfiguration.videoCodecPreference = codecs
        } else if let codec = try parseCodec(
            environment["SWIFT_MOONLIGHT_TEST_CODEC"],
            variableName: "SWIFT_MOONLIGHT_TEST_CODEC"
        ) {
            streamConfiguration.videoCodecPreference = [codec]
        }
        streamConfiguration.requestContinuousAudio = parseBool(
            environment["SWIFT_MOONLIGHT_TEST_CONTINUOUS_AUDIO"],
            defaultValue: true
        )
        try streamConfiguration.validate()
        let observationWindow = try parseObservationWindow(
            environment["SWIFT_MOONLIGHT_TEST_OBSERVATION_SECONDS"],
            defaultValue: defaultObservationWindow
        )
        let restartStreamConfiguration: StreamConfiguration?
        if let restartResolution = try parseResolution(
            environment["SWIFT_MOONLIGHT_TEST_RESTART_RESOLUTION"],
            variableName: "SWIFT_MOONLIGHT_TEST_RESTART_RESOLUTION"
        ) {
            var configuration = streamConfiguration
            configuration.resolution = restartResolution
            restartStreamConfiguration = configuration
        } else {
            restartStreamConfiguration = nil
        }

        return IntegrationHarnessConfiguration(
            endpoint: endpoint,
            pairingAuthProvider: {
                if let otpPassphrase, !otpPassphrase.isEmpty {
                    return .otp(pin: pin, passphrase: otpPassphrase)
                }
                return .pin(pin)
            },
            appID: appID,
            streamConfiguration: streamConfiguration,
            observationWindow: observationWindow,
            runtimeConfiguration: runtimeConfiguration,
            requireAudioPackets: parseBool(
                environment["SWIFT_MOONLIGHT_TEST_REQUIRE_AUDIO"],
                defaultValue: false
            ),
            inputProbeMode: parseInputProbeMode(environment["SWIFT_MOONLIGHT_TEST_INPUT_PROBE"]),
            inputProbeRepeatCount: try parsePositiveInt(
                environment["SWIFT_MOONLIGHT_TEST_INPUT_PROBE_REPEAT_COUNT"],
                variableName: "SWIFT_MOONLIGHT_TEST_INPUT_PROBE_REPEAT_COUNT"
            ),
            maxInputLatencyMs: try parsePositiveDouble(
                environment["SWIFT_MOONLIGHT_TEST_MAX_INPUT_LATENCY_MS"],
                variableName: "SWIFT_MOONLIGHT_TEST_MAX_INPUT_LATENCY_MS"
            ),
            maxMissingVideoPackets: try parseNonNegativeInt(
                environment["SWIFT_MOONLIGHT_TEST_MAX_MISSING_VIDEO_PACKETS"],
                variableName: "SWIFT_MOONLIGHT_TEST_MAX_MISSING_VIDEO_PACKETS"
            ),
            maxVideoDiscontinuities: try parseNonNegativeInt(
                environment["SWIFT_MOONLIGHT_TEST_MAX_VIDEO_DISCONTINUITIES"],
                variableName: "SWIFT_MOONLIGHT_TEST_MAX_VIDEO_DISCONTINUITIES"
            ),
            restartStreamConfiguration: restartStreamConfiguration,
            restartCount: try parseRestartCount(environment["SWIFT_MOONLIGHT_TEST_RESTART_COUNT"]),
            cancelCurrentAppBeforeLaunch: parseBool(
                environment["SWIFT_MOONLIGHT_TEST_CANCEL_BEFORE_LAUNCH"],
                defaultValue: false
            )
        )
    }

    private static func parseRestartCount(_ rawValue: String?) throws -> Int {
        try parsePositiveInt(rawValue, variableName: "SWIFT_MOONLIGHT_TEST_RESTART_COUNT")
    }

    private static func parsePositiveInt(_ rawValue: String?, variableName: String) throws -> Int {
        guard let rawValue, !rawValue.isEmpty else {
            return 1
        }
        guard let count = Int(rawValue), count > 0 else {
            throw MoonlightError(.unsupportedOperation, message: "Invalid \(variableName)")
        }
        return count
    }

    private static func parsePositiveIntOptional(_ rawValue: String?, variableName: String) throws -> Int? {
        guard let rawValue, !rawValue.isEmpty else {
            return nil
        }
        guard let value = Int(rawValue), value > 0 else {
            throw MoonlightError(.unsupportedOperation, message: "Invalid \(variableName)")
        }
        return value
    }

    private static func parsePositiveDouble(_ rawValue: String?, variableName: String) throws -> Double? {
        guard let rawValue, !rawValue.isEmpty else {
            return nil
        }
        guard let value = Double(rawValue), value > 0, value.isFinite else {
            throw MoonlightError(.unsupportedOperation, message: "Invalid \(variableName)")
        }
        return value
    }

    private static func parseNonNegativeInt(_ rawValue: String?, variableName: String) throws -> Int? {
        guard let rawValue, !rawValue.isEmpty else {
            return nil
        }
        guard let value = Int(rawValue), value >= 0 else {
            throw MoonlightError(.unsupportedOperation, message: "Invalid \(variableName)")
        }
        return value
    }

    private static func parseObservationWindow(_ rawValue: String?, defaultValue: Duration) throws -> Duration {
        guard let rawValue, !rawValue.isEmpty else {
            return defaultValue
        }
        guard let seconds = Double(rawValue), seconds > 0, seconds.isFinite else {
            throw MoonlightError(.unsupportedOperation, message: "Invalid SWIFT_MOONLIGHT_TEST_OBSERVATION_SECONDS")
        }
        return .milliseconds(Int64((seconds * 1000).rounded()))
    }

    private static func parseResolution(_ rawValue: String?, variableName: String) throws -> CGSize? {
        guard let rawValue, !rawValue.isEmpty else {
            return nil
        }

        let normalized = rawValue
            .lowercased()
            .replacingOccurrences(of: "×", with: "x")
        let parts = normalized.split(separator: "x")
        guard parts.count == 2,
              let width = Double(parts[0]),
              let height = Double(parts[1]),
              width > 0,
              height > 0 else {
            throw MoonlightError(.unsupportedOperation, message: "Invalid \(variableName)")
        }
        return CGSize(width: width, height: height)
    }

    private static func parseDynamicRange(
        _ rawValue: String?,
        variableName: String
    ) throws -> DynamicRangePreference? {
        guard let rawValue, !rawValue.isEmpty else {
            return nil
        }

        switch rawValue.lowercased() {
        case "sdr":
            return .sdr
        case "hdr":
            return .hdr
        default:
            throw MoonlightError(.unsupportedOperation, message: "Invalid \(variableName)")
        }
    }

    private static func parseCodecs(_ rawValue: String?, variableName: String) throws -> [VideoCodec]? {
        guard let rawValue, !rawValue.isEmpty else {
            return nil
        }

        let codecs = try rawValue
            .split(separator: ",")
            .map { try parseCodecValue(String($0), variableName: variableName) }
        guard !codecs.isEmpty else {
            throw MoonlightError(.unsupportedOperation, message: "Invalid \(variableName)")
        }
        return codecs
    }

    private static func parseCodec(_ rawValue: String?, variableName: String) throws -> VideoCodec? {
        guard let rawValue, !rawValue.isEmpty else {
            return nil
        }
        return try parseCodecValue(rawValue, variableName: variableName)
    }

    private static func parseCodecValue(_ rawValue: String, variableName: String) throws -> VideoCodec {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "hevc", "h265", "h.265":
            return .hevc
        case "h264", "h.264", "avc":
            return .h264
        case "av1":
            return .av1
        default:
            throw MoonlightError(.unsupportedOperation, message: "Invalid \(variableName)")
        }
    }

    private static func parseInputProbeMode(_ rawValue: String?) -> InputProbeMode {
        guard let rawValue, !rawValue.isEmpty else {
            return .noop
        }

        switch rawValue.lowercased() {
        case "0", "false", "off", "none", "disabled":
            return .disabled
        case "motion", "relative", "reversible", "reversible-relative-motion":
            return .reversibleRelativeMotion
        case "absolute", "absolute-sweep", "absolute-pointer", "absolute-pointer-sweep", "absolutepointersweep", "pointer":
            return .absolutePointerSweep
        case "1", "true", "on", "noop", "no-op":
            return .noop
        default:
            return .noop
        }
    }

    private static func parseBool(_ rawValue: String?, defaultValue: Bool) -> Bool {
        guard let rawValue, !rawValue.isEmpty else {
            return defaultValue
        }
        switch rawValue.lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return defaultValue
        }
    }

    private static func parseEndpoint(_ rawValue: String, defaultPort: Int) throws -> HostEndpoint {
        if let url = URL(string: rawValue), let host = url.host() {
            return HostEndpoint(address: host, port: url.port ?? defaultPort)
        }

        if let separatorIndex = rawValue.lastIndex(of: ":"),
           rawValue[rawValue.startIndex] != "[",
           rawValue[rawValue.index(after: separatorIndex)...].allSatisfy(\.isNumber),
           let port = Int(rawValue[rawValue.index(after: separatorIndex)...]) {
            let host = String(rawValue[..<separatorIndex])
            guard !host.isEmpty else {
                throw MoonlightError(.unsupportedOperation, message: "Invalid SWIFT_MOONLIGHT_TEST_HOST")
            }
            return HostEndpoint(address: host, port: port)
        }

        return HostEndpoint(address: rawValue, port: defaultPort)
    }
}

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

private struct SmokeSessionObservation: Sendable {
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

private extension SmokeRestartObservation {
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

public actor IntegrationHarness {
    private let client: MoonlightClient
    private let configuration: IntegrationHarnessConfiguration
    private let traceEnabled: Bool

    public init(client: MoonlightClient, configuration: IntegrationHarnessConfiguration, traceEnabled: Bool = false) {
        self.client = client
        self.configuration = configuration
        self.traceEnabled = traceEnabled
    }

    public static func production(
        storageDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logger: any MoonlightLogger = DefaultLogger(),
        metricsSink: any MetricsSink = NoopMetricsSink(),
        enableDiscovery: Bool = true,
        httpClient: (any HTTPClient)? = nil
    ) throws -> IntegrationHarness {
        let clientConfiguration = try ProductionClientFactory.configuration(
            storageDirectory: storageDirectory,
            logger: logger,
            metricsSink: metricsSink,
            enableDiscovery: enableDiscovery,
            httpClient: httpClient
        )
        return IntegrationHarness(
            client: MoonlightClient(configuration: clientConfiguration),
            configuration: try IntegrationHarnessConfiguration.fromEnvironment(environment),
            traceEnabled: environment["SWIFT_MOONLIGHT_SMOKE_TRACE"] == "1"
        )
    }

    public func runSmokeTest() async throws -> SmokeTestReport {
        trace("adding host \(configuration.endpoint.address):\(configuration.endpoint.port)")
        let knownHosts = try await client.discoverHosts()
        let host = try await selectHost(from: knownHosts)
        trace("refreshing host \(host.id.rawValue)")
        let refreshed = try await client.refreshHost(host.id)
        trace("refreshed host paired=\(refreshed.pairingState.isPaired)")

        let paired: Bool
        if refreshed.pairingState.isPaired {
            paired = true
        } else {
            trace("pairing host")
            let auth = try await configuration.pairingAuthProvider()
            let pairingResult = try await client.pair(hostID: host.id, auth: auth)
            paired = pairingResult.state.isPaired
            trace("pair result paired=\(paired)")
        }

        trace("fetching apps")
        let apps = try await client.fetchApps(hostID: host.id)
        let appsFetched = !apps.isEmpty
        let selectedAppID = selectAppID(from: apps)
        trace("apps fetched count=\(apps.count) selected=\(selectedAppID)")

        var preLaunchCancelAttempted = false
        if configuration.cancelCurrentAppBeforeLaunch {
            trace("cancelling current host app before launch")
            try await client.cancelCurrentApp(hostID: host.id)
            preLaunchCancelAttempted = true
            trace("current host app cancel completed")
        }

        trace("opening session")
        let session = try await client.openSession(
            hostID: host.id,
            appID: selectedAppID,
            configuration: configuration.streamConfiguration
        )
        try await attachSmokePlaybackComponents(to: session)

        let preparedRuntime = try await client.prepareRuntime(
            for: session,
            hostID: host.id,
            configuration: configuration.runtimeConfiguration
        )
        let restartCount = configuration.restartStreamConfiguration == nil ? 0 : configuration.restartCount
        let shouldRestart = restartCount > 0
        let primaryObservation = await observeSession(
            session: session,
            preparedRuntime: preparedRuntime,
            shouldProbeInput: true,
            shouldStopAfterObservation: !shouldRestart,
            phase: "primary"
        )
        let negotiatedSession = await session.negotiatedSession
        let audioExpected = configuration.requireAudioPackets && negotiatedSession?.audioFormat != nil

        let restartAttempted = shouldRestart
        var restartLaunchAccepted = false
        var restartObservation: SmokeSessionObservation?
        var restartObservations: [SmokeRestartObservation] = []
        var activePreparedRuntime = preparedRuntime
        if let restartStreamConfiguration = configuration.restartStreamConfiguration, restartCount > 0 {
            for restartIndex in 1...restartCount {
                do {
                    trace(
                        "restarting session \(restartIndex)/\(restartCount) at " +
                        "\(Int(restartStreamConfiguration.resolution.width))x\(Int(restartStreamConfiguration.resolution.height))"
                    )
                    let restarted = try await client.restartSession(
                        hostID: host.id,
                        appID: selectedAppID,
                        configuration: restartStreamConfiguration,
                        previousRuntime: activePreparedRuntime,
                        options: SessionRestartOptions(runtimeConfiguration: configuration.runtimeConfiguration)
                    )
                    activePreparedRuntime = restarted.preparedRuntime
                    if restartIndex == 1 {
                        restartLaunchAccepted = true
                    }
                    try await attachSmokePlaybackComponents(to: restarted.session)
                    let observation = await observeSession(
                        session: restarted.session,
                        preparedRuntime: restarted.preparedRuntime,
                        shouldProbeInput: false,
                        shouldStopAfterObservation: restartIndex == restartCount,
                        phase: restartCount == 1 ? "restart" : "restart \(restartIndex)"
                    )
                    if restartIndex == 1 {
                        restartObservation = observation
                    }
                    restartObservations.append(SmokeRestartObservation(index: restartIndex, observation: observation))
                } catch {
                    trace("restart \(restartIndex) failed: \((error as? MoonlightError)?.message ?? error.localizedDescription)")
                    restartObservations.append(SmokeRestartObservation(index: restartIndex, launchAccepted: false))
                    await activePreparedRuntime.stop()
                    break
                }
            }
        }

        return SmokeTestReport(
            paired: paired,
            appsFetched: appsFetched,
            preLaunchCancelAttempted: preLaunchCancelAttempted,
            launchAccepted: true,
            controlConnected: primaryObservation.controlConnected,
            inputConnected: primaryObservation.inputConnected,
            controlRoundTripTimeMs: primaryObservation.controlRoundTripTimeMs,
            controlRoundTripTimeVarianceMs: primaryObservation.controlRoundTripTimeVarianceMs,
            controlPacketLossRatio: primaryObservation.controlPacketLossRatio,
            controlPacketLossVarianceRatio: primaryObservation.controlPacketLossVarianceRatio,
            videoPacketsObserved: primaryObservation.videoPacketsObserved,
            audioPacketsObserved: primaryObservation.audioPacketsObserved,
            missingVideoPackets: primaryObservation.missingVideoPackets,
            reorderedVideoPackets: primaryObservation.reorderedVideoPackets,
            videoDiscontinuityEvents: primaryObservation.videoDiscontinuityEvents,
            videoFrameFECStatusReports: primaryObservation.videoFrameFECStatusReports,
            decodedVideoFrames: primaryObservation.decodedVideoFrames,
            renderedVideoFrames: primaryObservation.renderedVideoFrames,
            inputPacketsSent: primaryObservation.inputPacketsSent,
            averageInputQueueLatencyMs: primaryObservation.averageInputQueueLatencyMs,
            maxInputQueueLatencyMs: primaryObservation.maxInputQueueLatencyMs,
            averageInputTransportLatencyMs: primaryObservation.averageInputTransportLatencyMs,
            maxInputTransportLatencyMs: primaryObservation.maxInputTransportLatencyMs,
            inputProbeSucceeded: primaryObservation.inputProbeSucceeded,
            inputProbeMode: configuration.inputProbeMode,
            inputProbeRepeatCount: configuration.inputProbeRepeatCount,
            maxInputLatencyMs: configuration.maxInputLatencyMs,
            maxMissingVideoPackets: configuration.maxMissingVideoPackets,
            maxVideoDiscontinuities: configuration.maxVideoDiscontinuities,
            videoPacketTrace: primaryObservation.videoPacketTrace,
            audioExpected: audioExpected,
            unexpectedDisconnect: primaryObservation.unexpectedDisconnect,
            restartAttempted: restartAttempted,
            restartLaunchAccepted: restartLaunchAccepted,
            restartControlConnected: restartObservation?.controlConnected ?? false,
            restartInputConnected: restartObservation?.inputConnected ?? false,
            restartVideoPacketsObserved: restartObservation?.videoPacketsObserved ?? 0,
            restartAudioPacketsObserved: restartObservation?.audioPacketsObserved ?? 0,
            restartDecodedVideoFrames: restartObservation?.decodedVideoFrames ?? 0,
            restartRenderedVideoFrames: restartObservation?.renderedVideoFrames ?? 0,
            restartUnexpectedDisconnect: restartObservation?.unexpectedDisconnect ?? false,
            restartCountRequested: restartCount,
            restartObservations: restartObservations
        )
    }

    private func attachSmokePlaybackComponents(to session: MoonlightSession) async throws {
        if let negotiated = await session.negotiatedSession {
            trace("negotiated channels \(negotiated.channels.map { "\($0.descriptor.kind):\($0.descriptor.port):\($0.descriptor.metadata)" }.joined(separator: ", "))")
            trace("encryption features \(negotiated.encryptionFeatures.rawValue) continuousAudio=\(configuration.streamConfiguration.requestContinuousAudio)")
        }
        try await session.attachVideoDecoder(DiscardingVideoDecoder())
        try await session.attachRenderer(NullRenderer())
        try await session.attachAudioDecoder(SilenceAudioDecoder())
        try await session.attachAudioSink(NullAudioSink())
    }

    private func observeSession(
        session: MoonlightSession,
        preparedRuntime: PreparedSessionRuntime,
        shouldProbeInput: Bool,
        shouldStopAfterObservation: Bool,
        phase: String
    ) async -> SmokeSessionObservation {
        if let videoSource = preparedRuntime.sockets.videoSource {
            if let port = try? await videoSource.localPort() {
                trace("\(phase) video socket local port \(port)")
            }
        }
        if let audioSource = preparedRuntime.sockets.audioSource {
            if let port = try? await audioSource.localPort() {
                trace("\(phase) audio socket local port \(port)")
            }
        }
        trace("starting \(phase) runtime")
        await preparedRuntime.runtime.start()

        let inputProbeSucceeded = shouldProbeInput
            ? await probeInputIfConnected(session: session, sockets: preparedRuntime.sockets)
            : true
        let inputMetrics = await session.currentMetricsSnapshot()
        trace("observing \(phase) for \(configuration.observationWindow)")
        try? await Task.sleep(for: configuration.observationWindow)

        let runtimeSnapshot = await preparedRuntime.runtime.snapshot()
        let controlRTTText = runtimeSnapshot.controlRoundTripTimeMs.map { String($0) } ?? "nil"
        let controlLossText = runtimeSnapshot.controlPacketLossRatio.map { String($0) } ?? "nil"
        trace(
            "\(phase) runtime snapshot videoPackets=\(runtimeSnapshot.videoPacketsObserved) " +
            "audioPackets=\(runtimeSnapshot.audioPacketsObserved) " +
            "controlRttMs=\(controlRTTText) " +
            "controlLossRatio=\(controlLossText) " +
            "missingVideo=\(runtimeSnapshot.missingVideoPackets) " +
            "reorderedVideo=\(runtimeSnapshot.reorderedVideoPackets) " +
            "videoDiscontinuities=\(runtimeSnapshot.videoDiscontinuityEvents) " +
            "fecStatusReports=\(runtimeSnapshot.videoFrameFECStatusReports)"
        )
        if shouldStopAfterObservation {
            trace("stopping \(phase) runtime")
            await preparedRuntime.stop()
            trace("\(phase) runtime stopped")
        }
        let pipelineStats = await session.mediaPipelineHandle().snapshot()
        trace("\(phase) pipeline snapshot decodedVideo=\(pipelineStats.decodedVideoFrames) renderedVideo=\(pipelineStats.renderedVideoFrames)")

        return SmokeSessionObservation(
            controlConnected: preparedRuntime.sockets.controlTransport != nil,
            inputConnected: preparedRuntime.sockets.inputTransport != nil,
            controlRoundTripTimeMs: runtimeSnapshot.controlRoundTripTimeMs,
            controlRoundTripTimeVarianceMs: runtimeSnapshot.controlRoundTripTimeVarianceMs,
            controlPacketLossRatio: runtimeSnapshot.controlPacketLossRatio,
            controlPacketLossVarianceRatio: runtimeSnapshot.controlPacketLossVarianceRatio,
            videoPacketsObserved: runtimeSnapshot.videoPacketsObserved,
            audioPacketsObserved: runtimeSnapshot.audioPacketsObserved,
            missingVideoPackets: runtimeSnapshot.missingVideoPackets,
            reorderedVideoPackets: runtimeSnapshot.reorderedVideoPackets,
            videoDiscontinuityEvents: runtimeSnapshot.videoDiscontinuityEvents,
            videoFrameFECStatusReports: runtimeSnapshot.videoFrameFECStatusReports,
            decodedVideoFrames: pipelineStats.decodedVideoFrames,
            renderedVideoFrames: pipelineStats.renderedVideoFrames,
            inputPacketsSent: inputMetrics.inputPacketsSent,
            averageInputQueueLatencyMs: inputMetrics.averageInputQueueLatencyMs,
            maxInputQueueLatencyMs: inputMetrics.maxInputQueueLatencyMs,
            averageInputTransportLatencyMs: inputMetrics.averageInputTransportLatencyMs,
            maxInputTransportLatencyMs: inputMetrics.maxInputTransportLatencyMs,
            inputProbeSucceeded: inputProbeSucceeded,
            videoPacketTrace: runtimeSnapshot.videoPacketTrace,
            unexpectedDisconnect: runtimeSnapshot.unexpectedDisconnect
        )
    }

    private func selectHost(from knownHosts: [MoonlightHost]) async throws -> MoonlightHost {
        let exactMatches = knownHosts.filter {
            $0.endpoint.address == configuration.endpoint.address &&
            $0.endpoint.port == configuration.endpoint.port
        }
        if let pairedExactMatch = exactMatches.first(where: \.pairingState.isPaired) {
            trace("reusing paired stored host \(pairedExactMatch.id.rawValue)")
            return pairedExactMatch
        }

        let pairedHosts = knownHosts.filter(\.pairingState.isPaired)
        if pairedHosts.count == 1 {
            trace("adopting override endpoint for paired host \(pairedHosts[0].id.rawValue)")
            return try await client.updateHostEndpoint(hostID: pairedHosts[0].id, endpoint: configuration.endpoint)
        }

        if let exactMatch = exactMatches.first {
            trace("reusing stored host \(exactMatch.id.rawValue)")
            return exactMatch
        }

        trace("stored host not found; adding host")
        return try await client.addHost(configuration.endpoint)
    }

    private func selectAppID(from apps: [RemoteApp]) -> RemoteApp.ID {
        let requested = configuration.appID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let app = apps.first(where: { $0.id == requested }) {
            return app.id
        }
        if let app = apps.first(where: { $0.name.caseInsensitiveCompare(requested) == .orderedSame }) {
            return app.id
        }
        if requested.caseInsensitiveCompare("desktop") == .orderedSame,
           let desktop = apps.first(where: {
               $0.id.caseInsensitiveCompare("desktop") == .orderedSame ||
               $0.name.caseInsensitiveCompare("desktop") == .orderedSame
           }) {
            return desktop.id
        }
        return configuration.appID
    }

    private func probeInputIfConnected(session: MoonlightSession, sockets: ChannelSocketSet) async -> Bool {
        guard sockets.inputTransport != nil else {
            return false
        }

        guard configuration.inputProbeMode != .disabled else {
            trace("input probe disabled")
            return true
        }

        do {
            for _ in 0..<configuration.inputProbeRepeatCount {
                switch configuration.inputProbeMode {
                case .disabled:
                    return true
                case .noop:
                    try await session.send(.mouse(.relativeMove(dx: 0, dy: 0)))
                    try await session.send(.mouse(.verticalScroll(delta: 0)))
                    try await session.flushPendingInput()
                case .reversibleRelativeMotion:
                    try await session.send(.mouse(.relativeMove(dx: 1, dy: 0)))
                    try await session.flushPendingInput()
                    try await session.send(.mouse(.relativeMove(dx: -1, dy: 0)))
                    try await session.flushPendingInput()
                case .absolutePointerSweep:
                    try await session.send(.mouse(.absoluteMove(x: 0.25, y: 0.5)))
                    try await session.flushPendingInput()
                    try await session.send(.mouse(.absoluteMove(x: 0.75, y: 0.5)))
                    try await session.flushPendingInput()
                    try await session.send(.mouse(.absoluteMove(x: 0.5, y: 0.5)))
                    try await session.flushPendingInput()
                }
            }
            trace("input probe sent \(configuration.inputProbeRepeatCount) \(configuration.inputProbeMode.rawValue) iteration(s)")
            return true
        } catch {
            let detail = (error as? MoonlightError)?.message ?? error.localizedDescription
            trace("input probe failed: \(detail)")
            return false
        }
    }

    private func trace(_ message: String) {
        guard traceEnabled else { return }
        fputs("[smoke] \(message)\n", stderr)
        fflush(stderr)
    }
}
