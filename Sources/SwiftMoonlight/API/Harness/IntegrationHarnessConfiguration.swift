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
