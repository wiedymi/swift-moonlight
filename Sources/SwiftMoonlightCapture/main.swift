import Foundation
import SwiftMoonlight
#if canImport(CoreImage) && canImport(CoreVideo) && canImport(ImageIO) && canImport(UniformTypeIdentifiers)
import CoreGraphics
import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
#if canImport(Metal)
import Metal
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main
struct CaptureCommand {
    static func main() async {
        do {
            let configuration = try CaptureConfiguration.fromEnvironment()
            let report = try await HeadlessCaptureRunner(configuration: configuration).run()
            print(render(report))
            try writeJSONReportIfRequested(report)
            if !report.passed {
                exit(EXIT_FAILURE)
            }
        } catch let error as MoonlightError {
            fputs("swift-moonlight-capture failed: \(error.message)\n", stderr)
            exit(EXIT_FAILURE)
        } catch {
            fputs("swift-moonlight-capture failed: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func render(_ report: CaptureReport) -> String {
        let warnings = report.warnings.isEmpty ? "[]" : report.warnings.joined(separator: " | ")
        let failures = report.failures.isEmpty ? "[]" : report.failures.joined(separator: "; ")
        let lines = [
            "host=\(report.host.address):\(report.host.port)",
            "hostKind=\(hostKindName(report.hostKind))",
            "appID=\(report.appID)",
            "outputDirectory=\(report.outputDirectory.path)",
            "capturedImages=\(report.capturedImages)",
            "firstImage=\(report.firstImagePath ?? "")",
            "lastImage=\(report.lastImagePath ?? "")",
            "frameMetadata=\(report.frameMetadataPath ?? "")",
            "capturedMetalImages=\(report.capturedMetalImages)",
            "firstMetalImage=\(report.firstMetalImagePath ?? "")",
            "lastMetalImage=\(report.lastMetalImagePath ?? "")",
            "metalReadbackPairs=\(report.metalReadbackDelta?.framePairs ?? 0)",
            "metalReadbackMeanRGBDelta=\(stringValue(report.metalReadbackDelta?.meanRGBDelta))",
            "metalReadbackRMSRGBDelta=\(stringValue(report.metalReadbackDelta?.rmsRGBDelta))",
            "metalReadbackMaxRGBDelta=\(report.metalReadbackDelta?.maxRGBDelta.description ?? "")",
            "metalReadbackChangedPixels=\(report.metalReadbackDelta?.changedPixels.description ?? "")",
            "metalReadbackChangedPixelRatio=\(stringValue(report.metalReadbackDelta?.changedPixelRatio))",
            "hdrModeEnabled=\(report.hdrMode?.enabled.description ?? "")",
            "hdrModeMetadataPresent=\(report.hdrMode?.metadataPresent.description ?? "")",
            "inputVisualProbeMode=\(report.inputVisualProbe?.mode.description ?? "disabled")",
            "inputVisualProbeAttempted=\(report.inputVisualProbe?.attempted.description ?? "false")",
            "inputVisualProbePassed=\(report.inputVisualProbe?.passed.description ?? "")",
            "inputVisualProbeBaselineImage=\(report.inputVisualProbe?.baselineImagePath ?? "")",
            "inputVisualProbeComparisonImage=\(report.inputVisualProbe?.comparisonImagePath ?? "")",
            "inputVisualProbeMeanRGBDelta=\(stringValue(report.inputVisualProbe?.meanRGBDelta))",
            "inputVisualProbeRMSRGBDelta=\(stringValue(report.inputVisualProbe?.rmsRGBDelta))",
            "inputVisualProbeMaxRGBDelta=\(report.inputVisualProbe?.maxRGBDelta?.description ?? "")",
            "inputVisualProbeChangedPixels=\(report.inputVisualProbe?.changedPixels?.description ?? "")",
            "inputVisualProbeChangedPixelRatio=\(stringValue(report.inputVisualProbe?.changedPixelRatio))",
            "inputVisualProbeChangedBounds=\(report.inputVisualProbe?.changedBounds?.description ?? "")",
            "inputVisualProbeExpectedRegions=\(report.inputVisualProbe?.expectedRegions.map(\.description).joined(separator: " | ") ?? "")",
            "inputVisualTargetPresence=\(report.inputVisualProbe?.targetPresence?.description ?? "")",
            "inputVisualProbeInputPacketsBefore=\(report.inputVisualProbe?.inputPacketsBefore.description ?? "")",
            "inputVisualProbeInputPacketsAfter=\(report.inputVisualProbe?.inputPacketsAfter.description ?? "")",
            "paired=\(report.paired)",
            "controlConnected=\(report.controlConnected)",
            "inputConnected=\(report.inputConnected)",
            "inputEventsSent=\(report.metrics.inputEventsSent)",
            "inputPacketsSent=\(report.metrics.inputPacketsSent)",
            "averageInputQueueLatencyMs=\(stringValue(report.metrics.averageInputQueueLatencyMs))",
            "maxInputQueueLatencyMs=\(stringValue(report.metrics.maxInputQueueLatencyMs))",
            "averageInputTransportLatencyMs=\(stringValue(report.metrics.averageInputTransportLatencyMs))",
            "maxInputTransportLatencyMs=\(stringValue(report.metrics.maxInputTransportLatencyMs))",
            "videoPacketsObserved=\(report.metrics.videoPacketsObserved)",
            "audioPacketsObserved=\(report.metrics.audioPacketsObserved)",
            "missingVideoPackets=\(report.metrics.missingVideoPackets)",
            "reorderedVideoPackets=\(report.metrics.reorderedVideoPackets)",
            "videoDiscontinuityEvents=\(report.metrics.videoDiscontinuityEvents)",
            "recoverableVideoDecodeFailures=\(report.metrics.recoverableVideoDecodeFailures)",
            "decodedVideoFrames=\(report.metrics.decodedVideoFrames)",
            "renderedVideoFrames=\(report.metrics.renderedVideoFrames)",
            "decodedAudioBuffers=\(report.metrics.decodedAudioBuffers)",
            "playedAudioBuffers=\(report.metrics.playedAudioBuffers)",
            "audioWAV=\(report.audioWAVPath ?? "")",
            "audioBytes=\(report.audioBytes)",
            "averageVideoDecodeLatencyMs=\(stringValue(report.metrics.averageVideoDecodeLatencyMs))",
            "averageAudioDecodeLatencyMs=\(stringValue(report.metrics.averageAudioDecodeLatencyMs))",
            "maxVideoDecodeLatencyMs=\(stringValue(report.metrics.maxVideoDecodeLatencyMs))",
            "maxAudioDecodeLatencyMs=\(stringValue(report.metrics.maxAudioDecodeLatencyMs))",
            "averageHostProcessingLatencyMs=\(stringValue(report.metrics.averageHostProcessingLatencyMs))",
            "maxHostProcessingLatencyMs=\(stringValue(report.metrics.maxHostProcessingLatencyMs))",
            "unexpectedDisconnect=\(report.metrics.unexpectedDisconnect)",
            "passed=\(report.passed)",
            "warnings=\(warnings)",
            "failures=\(failures)",
        ]
        return lines.joined(separator: "\n")
    }

    private static func stringValue(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(value)
    }

    private static func hostKindName(_ kind: HostKind) -> String {
        switch kind {
        case .sunshine:
            return "sunshine"
        case .apollo:
            return "apollo"
        case .unknown:
            return "unknown"
        }
    }

    private static func writeJSONReportIfRequested(_ report: CaptureReport) throws {
        guard let rawPath = ProcessInfo.processInfo.environment["SWIFT_MOONLIGHT_CAPTURE_REPORT_JSON"],
              !rawPath.isEmpty
        else {
            return
        }

        let fileURL = URL(fileURLWithPath: rawPath)
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(CaptureJSONReport(report: report))
        try data.write(to: fileURL, options: .atomic)
    }
}

private struct CaptureConfiguration: Sendable {
    let storageDirectory: URL
    let outputDirectory: URL
    let hostOverride: HostEndpoint?
    let appIDOverride: String?
    let frameLimit: Int
    let timeout: Duration
    let traceDecode: Bool
    let traceAudio: Bool
    let disableMetalReadback: Bool
    let cancelBeforeLaunch: Bool
    let requireHDR: Bool
    let requireAudio: Bool
    let inputVisualProbeMode: CaptureInputVisualProbeMode
    let requireInputVisualProbe: Bool
    let inputVisualProbeMinChangedPixelRatio: Double
    let requireInputVisualExpectedRegions: Bool
    let inputVisualExpectedRegionMinChangedPixelRatio: Double
    let inputVisualTargetURL: String?
    let inputVisualOpenHelperURL: String?
    let inputVisualExpectedFrame: InputVisualExpectedFrame
    let maxMissingVideoPackets: Int?
    let maxVideoDiscontinuities: Int?
    let maxRecoverableVideoDecodeFailures: Int?
    let streamConfiguration: StreamConfiguration
    let runtimeConfiguration: StreamRuntimeConfiguration

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> CaptureConfiguration {
        let storageDirectory = try resolveStorageDirectory(environment)
        let outputDirectory = try resolveOutputDirectory(environment)
        let hostOverride: HostEndpoint?
        if let rawHost = environment["SWIFT_MOONLIGHT_TEST_HOST"], !rawHost.isEmpty {
            hostOverride = try parseEndpoint(rawHost, defaultPort: 47_989)
        } else {
            hostOverride = nil
        }
        let appIDOverride = environment["SWIFT_MOONLIGHT_TEST_APP_ID"].flatMap {
            $0.isEmpty ? nil : $0
        }
        let frameLimit = max(1, Int(environment["SWIFT_MOONLIGHT_CAPTURE_FRAME_LIMIT"] ?? "") ?? 3)
        let timeoutSeconds = max(1, Int(environment["SWIFT_MOONLIGHT_CAPTURE_TIMEOUT_SECONDS"] ?? "") ?? 20)

        var streamConfiguration = try streamConfiguration(from: environment)
        streamConfiguration.requestContinuousAudio = environment["SWIFT_MOONLIGHT_CAPTURE_CONTINUOUS_AUDIO"] != "0"
        let inputVisualProbeMode = try CaptureInputVisualProbeMode.fromEnvironment(environment)
        let inputVisualProbeMinChangedPixelRatio = try parseNonNegativeDouble(
            environment["SWIFT_MOONLIGHT_CAPTURE_INPUT_VISUAL_MIN_CHANGED_PIXEL_RATIO"],
            variableName: "SWIFT_MOONLIGHT_CAPTURE_INPUT_VISUAL_MIN_CHANGED_PIXEL_RATIO",
            defaultValue: 0.00005
        )
        let inputVisualExpectedRegionMinChangedPixelRatio = try parseNonNegativeDouble(
            environment["SWIFT_MOONLIGHT_CAPTURE_INPUT_VISUAL_EXPECTED_REGION_MIN_CHANGED_PIXEL_RATIO"],
            variableName: "SWIFT_MOONLIGHT_CAPTURE_INPUT_VISUAL_EXPECTED_REGION_MIN_CHANGED_PIXEL_RATIO",
            defaultValue: 0.001
        )
        let inputVisualTargetURL = environment["SWIFT_MOONLIGHT_CAPTURE_INPUT_VISUAL_TARGET_URL"].flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        let inputVisualOpenHelperURL = environment["SWIFT_MOONLIGHT_CAPTURE_INPUT_VISUAL_OPEN_HELPER_URL"].flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        let inputVisualExpectedFrame = try InputVisualExpectedFrame.fromEnvironment(environment)
        let maxMissingVideoPackets = try parseNonNegativeInt(
            environment["SWIFT_MOONLIGHT_CAPTURE_MAX_MISSING_VIDEO_PACKETS"],
            variableName: "SWIFT_MOONLIGHT_CAPTURE_MAX_MISSING_VIDEO_PACKETS"
        )
        let maxVideoDiscontinuities = try parseNonNegativeInt(
            environment["SWIFT_MOONLIGHT_CAPTURE_MAX_VIDEO_DISCONTINUITIES"],
            variableName: "SWIFT_MOONLIGHT_CAPTURE_MAX_VIDEO_DISCONTINUITIES"
        )
        let maxRecoverableVideoDecodeFailures = try parseNonNegativeInt(
            environment["SWIFT_MOONLIGHT_CAPTURE_MAX_RECOVERABLE_VIDEO_DECODE_FAILURES"],
            variableName: "SWIFT_MOONLIGHT_CAPTURE_MAX_RECOVERABLE_VIDEO_DECODE_FAILURES"
        )

        return CaptureConfiguration(
            storageDirectory: storageDirectory,
            outputDirectory: outputDirectory,
            hostOverride: hostOverride,
            appIDOverride: appIDOverride,
            frameLimit: frameLimit,
            timeout: .seconds(timeoutSeconds),
            traceDecode: environment["SWIFT_MOONLIGHT_CAPTURE_TRACE_DECODE"] == "1",
            traceAudio: environment["SWIFT_MOONLIGHT_CAPTURE_TRACE_AUDIO"] == "1",
            disableMetalReadback: environment["SWIFT_MOONLIGHT_CAPTURE_DISABLE_METAL_READBACK"] == "1",
            cancelBeforeLaunch: environment["SWIFT_MOONLIGHT_CAPTURE_CANCEL_BEFORE_LAUNCH"] == "1",
            requireHDR: environment["SWIFT_MOONLIGHT_CAPTURE_REQUIRE_HDR"] == "1",
            requireAudio: environment["SWIFT_MOONLIGHT_CAPTURE_REQUIRE_AUDIO"] == "1",
            inputVisualProbeMode: inputVisualProbeMode,
            requireInputVisualProbe: environment["SWIFT_MOONLIGHT_CAPTURE_REQUIRE_INPUT_VISUAL_PROBE"] == "1",
            inputVisualProbeMinChangedPixelRatio: inputVisualProbeMinChangedPixelRatio,
            requireInputVisualExpectedRegions: environment["SWIFT_MOONLIGHT_CAPTURE_REQUIRE_INPUT_VISUAL_EXPECTED_REGIONS"] == "1",
            inputVisualExpectedRegionMinChangedPixelRatio: inputVisualExpectedRegionMinChangedPixelRatio,
            inputVisualTargetURL: inputVisualTargetURL,
            inputVisualOpenHelperURL: inputVisualOpenHelperURL,
            inputVisualExpectedFrame: inputVisualExpectedFrame,
            maxMissingVideoPackets: maxMissingVideoPackets,
            maxVideoDiscontinuities: maxVideoDiscontinuities,
            maxRecoverableVideoDecodeFailures: maxRecoverableVideoDecodeFailures,
            streamConfiguration: streamConfiguration,
            runtimeConfiguration: .init()
        )
    }

    private static func resolveStorageDirectory(_ environment: [String: String]) throws -> URL {
        let rawValue = environment["SWIFT_MOONLIGHT_TEST_STORAGE_DIR"]?.isEmpty == false
            ? environment["SWIFT_MOONLIGHT_TEST_STORAGE_DIR"]!
            : NSString(string: "~/Library/Application Support/swift-moonlight-test-app").expandingTildeInPath
        let url = URL(fileURLWithPath: rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func resolveOutputDirectory(_ environment: [String: String]) throws -> URL {
        if let rawValue = environment["SWIFT_MOONLIGHT_CAPTURE_OUTPUT_DIR"], !rawValue.isEmpty {
            let url = URL(fileURLWithPath: rawValue, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appending(path: "swift-moonlight-capture-\(timestamp)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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

        guard !rawValue.isEmpty else {
            throw MoonlightError(.unsupportedOperation, message: "Invalid SWIFT_MOONLIGHT_TEST_HOST")
        }
        return HostEndpoint(address: rawValue, port: defaultPort)
    }

    private static func streamConfiguration(from environment: [String: String]) throws -> StreamConfiguration {
        var configuration = StreamConfiguration.default1080p60

        if let rawValue = environment["SWIFT_MOONLIGHT_CAPTURE_RESOLUTION"], !rawValue.isEmpty {
            configuration.resolution = try parseResolution(rawValue)
        }
        if let rawValue = environment["SWIFT_MOONLIGHT_CAPTURE_FPS"], !rawValue.isEmpty {
            guard let frameRate = Int(rawValue) else {
                throw MoonlightError(.unsupportedOperation, message: "Invalid SWIFT_MOONLIGHT_CAPTURE_FPS")
            }
            configuration.frameRate = frameRate
        }
        if let rawValue = environment["SWIFT_MOONLIGHT_CAPTURE_BITRATE_KBPS"], !rawValue.isEmpty {
            guard let bitrate = Int(rawValue) else {
                throw MoonlightError(.unsupportedOperation, message: "Invalid SWIFT_MOONLIGHT_CAPTURE_BITRATE_KBPS")
            }
            configuration.bitrateKbps = bitrate
        }
        if let rawValue = environment["SWIFT_MOONLIGHT_CAPTURE_DYNAMIC_RANGE"], !rawValue.isEmpty {
            configuration.dynamicRange = try parseDynamicRange(rawValue)
        }
        if let rawValue = environment["SWIFT_MOONLIGHT_CAPTURE_CODECS"], !rawValue.isEmpty {
            configuration.videoCodecPreference = try parseCodecs(rawValue)
        } else if let rawValue = environment["SWIFT_MOONLIGHT_CAPTURE_CODEC"], !rawValue.isEmpty {
            configuration.videoCodecPreference = [try parseCodec(rawValue)]
        }

        try configuration.validate()
        return configuration
    }

    private static func parseResolution(_ rawValue: String) throws -> CGSize {
        let normalized = rawValue.lowercased().replacingOccurrences(of: " ", with: "")
        let parts = normalized.split(separator: "x")
        guard parts.count == 2,
              let width = Int(parts[0]),
              let height = Int(parts[1])
        else {
            throw MoonlightError(.unsupportedOperation, message: "Invalid SWIFT_MOONLIGHT_CAPTURE_RESOLUTION")
        }
        return CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    private static func parseDynamicRange(_ rawValue: String) throws -> DynamicRangePreference {
        switch rawValue.lowercased() {
        case "sdr":
            return .sdr
        case "hdr":
            return .hdr
        default:
            throw MoonlightError(.unsupportedOperation, message: "Invalid SWIFT_MOONLIGHT_CAPTURE_DYNAMIC_RANGE")
        }
    }

    private static func parseCodecs(_ rawValue: String) throws -> [VideoCodec] {
        let codecs = try rawValue
            .split(separator: ",")
            .map { try parseCodec(String($0)) }
        guard !codecs.isEmpty else {
            throw MoonlightError(.unsupportedOperation, message: "Invalid SWIFT_MOONLIGHT_CAPTURE_CODECS")
        }
        return codecs
    }

    private static func parseCodec(_ rawValue: String) throws -> VideoCodec {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "hevc", "h265", "h.265":
            return .hevc
        case "h264", "h.264", "avc":
            return .h264
        case "av1":
            return .av1
        default:
            throw MoonlightError(.unsupportedOperation, message: "Invalid capture codec: \(rawValue)")
        }
    }

    private static func parseNonNegativeDouble(
        _ rawValue: String?,
        variableName: String,
        defaultValue: Double
    ) throws -> Double {
        guard let rawValue, !rawValue.isEmpty else {
            return defaultValue
        }
        guard let value = Double(rawValue), value >= 0 else {
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
}

private enum CaptureInputVisualProbeMode: String, Sendable, Equatable, Codable, CustomStringConvertible {
    case disabled
    case reversibleRelativeMotion = "relative"
    case absolutePointerSweep = "absolute"

    static func fromEnvironment(_ environment: [String: String]) throws -> CaptureInputVisualProbeMode {
        guard let rawValue = environment["SWIFT_MOONLIGHT_CAPTURE_INPUT_VISUAL_PROBE"],
              !rawValue.isEmpty
        else {
            return .disabled
        }

        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "0", "disabled", "off", "none":
            return .disabled
        case "1", "relative", "motion", "reversible", "reversiblerelativemotion":
            return .reversibleRelativeMotion
        case "absolute", "absolute-sweep", "absolute-pointer", "absolute-pointer-sweep", "absolutepointersweep", "pointer":
            return .absolutePointerSweep
        default:
            throw MoonlightError(
                .unsupportedOperation,
                message: "Invalid SWIFT_MOONLIGHT_CAPTURE_INPUT_VISUAL_PROBE"
            )
        }
    }

    var additionalFrameLimit: Int {
        switch self {
        case .disabled:
            return 0
        case .reversibleRelativeMotion:
            return 4
        case .absolutePointerSweep:
            return 6
        }
    }

    var description: String {
        rawValue
    }
}

private struct InputVisualExpectedFrame: Sendable, Equatable, Codable {
    var minX: Double
    var minY: Double
    var width: Double
    var height: Double

    static let full = InputVisualExpectedFrame(minX: 0, minY: 0, width: 1, height: 1)

    static func fromEnvironment(_ environment: [String: String]) throws -> InputVisualExpectedFrame {
        guard let rawValue = environment["SWIFT_MOONLIGHT_CAPTURE_INPUT_VISUAL_EXPECTED_FRAME"],
              !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .full
        }

        let parts = rawValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 4,
              let minX = Double(parts[0]),
              let minY = Double(parts[1]),
              let width = Double(parts[2]),
              let height = Double(parts[3]),
              minX >= 0,
              minY >= 0,
              width > 0,
              height > 0,
              minX + width <= 1,
              minY + height <= 1
        else {
            throw MoonlightError(
                .unsupportedOperation,
                message: "Invalid SWIFT_MOONLIGHT_CAPTURE_INPUT_VISUAL_EXPECTED_FRAME"
            )
        }

        return InputVisualExpectedFrame(minX: minX, minY: minY, width: width, height: height)
    }

    func x(_ ratio: Double) -> Double {
        minX + width * ratio
    }

    func y(_ ratio: Double) -> Double {
        minY + height * ratio
    }
}

private struct CaptureReport: Sendable {
    let host: HostEndpoint
    let hostKind: HostKind
    let appID: String
    let outputDirectory: URL
    let capturedImages: Int
    let firstImagePath: String?
    let lastImagePath: String?
    let frameMetadataPath: String?
    let capturedMetalImages: Int
    let firstMetalImagePath: String?
    let lastMetalImagePath: String?
    let metalReadbackDelta: ImageDeltaSummary?
    let hdrMode: HDRModeCaptureState?
    let inputVisualProbe: InputVisualProbeResult?
    let audioWAVPath: String?
    let audioBytes: Int
    let paired: Bool
    let controlConnected: Bool
    let inputConnected: Bool
    let metrics: SessionMetricsSnapshot
    let warnings: [String]
    let failures: [String]

    var passed: Bool {
        failures.isEmpty
    }
}

private struct ImageDeltaBounds: Sendable, Codable, CustomStringConvertible {
    let minX: Int
    let minY: Int
    let maxX: Int
    let maxY: Int

    var description: String {
        "\(minX),\(minY)-\(maxX),\(maxY)"
    }
}

private struct ImageDeltaRegionRequest: Sendable {
    let name: String
    let centerXRatio: Double
    let centerYRatio: Double
    let halfExtent: Int
}

private struct ImageDeltaRegionSummary: Sendable, Codable, CustomStringConvertible {
    let name: String
    let bounds: ImageDeltaBounds
    let changedPixels: Int
    let totalPixels: Int
    let changedPixelRatio: Double

    var description: String {
        "\(name):\(bounds.description):\(String(format: "%.5f", changedPixelRatio))"
    }
}

private struct InputVisualTargetPresenceSummary: Sendable, Codable, CustomStringConvertible {
    let detected: Bool
    let sentinelRatios: [Double]

    var description: String {
        let ratios = sentinelRatios.map { String(format: "%.3f", $0) }.joined(separator: ",")
        return "detected=\(detected) sentinel=[\(ratios)]"
    }
}

private struct ImageDeltaSummary: Sendable, Codable {
    let framePairs: Int
    let meanRGBDelta: Double
    let rmsRGBDelta: Double
    let maxRGBDelta: UInt8
    let changedPixels: Int
    let totalPixels: Int
    let changedPixelRatio: Double
    let changedBounds: ImageDeltaBounds?

    var indicatesSDRRegression: Bool {
        meanRGBDelta > 32 || maxRGBDelta > 64
    }

    func indicatesVisualChange(minChangedPixelRatio: Double) -> Bool {
        changedPixelRatio >= minChangedPixelRatio
    }
}

private struct HDRModeCaptureState: Sendable, Codable {
    let enabled: Bool
    let metadataPresent: Bool
    let maxDisplayLuminance: UInt16?
    let maxContentLightLevel: UInt16?
    let maxFrameAverageLightLevel: UInt16?

    init(update: HDRModeUpdate) {
        self.enabled = update.enabled
        self.metadataPresent = update.metadata != nil
        self.maxDisplayLuminance = update.metadata?.maxDisplayLuminance
        self.maxContentLightLevel = update.metadata?.maxContentLightLevel
        self.maxFrameAverageLightLevel = update.metadata?.maxFrameAverageLightLevel
    }
}

private struct InputVisualProbeResult: Sendable, Codable {
    let mode: CaptureInputVisualProbeMode
    let attempted: Bool
    let passed: Bool
    let inputPacketsBefore: Int
    let inputPacketsAfter: Int
    let baselineImagePath: String?
    let comparisonImagePath: String?
    let meanRGBDelta: Double?
    let rmsRGBDelta: Double?
    let maxRGBDelta: UInt8?
    let changedPixels: Int?
    let changedPixelRatio: Double?
    let changedBounds: ImageDeltaBounds?
    let expectedRegions: [ImageDeltaRegionSummary]
    let targetPresence: InputVisualTargetPresenceSummary?
    let warning: String?
}

private struct CaptureJSONReport: Codable {
    let schemaVersion: Int
    let kind: String
    let generatedAt: String
    let host: HostPayload
    let hostKind: String
    let appID: String
    let outputDirectory: String
    let capturedImages: Int
    let firstImagePath: String?
    let lastImagePath: String?
    let frameMetadataPath: String?
    let capturedMetalImages: Int
    let firstMetalImagePath: String?
    let lastMetalImagePath: String?
    let metalReadbackDelta: ImageDeltaSummary?
    let hdrMode: HDRModeCaptureState?
    let inputVisualProbe: InputVisualProbeResult?
    let audioWAVPath: String?
    let audioBytes: Int
    let paired: Bool
    let controlConnected: Bool
    let inputConnected: Bool
    let metrics: SessionMetricsSnapshot
    let passed: Bool
    let warnings: [String]
    let failures: [String]

    init(report: CaptureReport) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.schemaVersion = 1
        self.kind = "swift-moonlight-capture"
        self.generatedAt = formatter.string(from: Date())
        self.host = HostPayload(endpoint: report.host)
        self.hostKind = Self.hostKindName(report.hostKind)
        self.appID = report.appID
        self.outputDirectory = report.outputDirectory.path
        self.capturedImages = report.capturedImages
        self.firstImagePath = report.firstImagePath
        self.lastImagePath = report.lastImagePath
        self.frameMetadataPath = report.frameMetadataPath
        self.capturedMetalImages = report.capturedMetalImages
        self.firstMetalImagePath = report.firstMetalImagePath
        self.lastMetalImagePath = report.lastMetalImagePath
        self.metalReadbackDelta = report.metalReadbackDelta
        self.hdrMode = report.hdrMode
        self.inputVisualProbe = report.inputVisualProbe
        self.audioWAVPath = report.audioWAVPath
        self.audioBytes = report.audioBytes
        self.paired = report.paired
        self.controlConnected = report.controlConnected
        self.inputConnected = report.inputConnected
        self.metrics = report.metrics
        self.passed = report.passed
        self.warnings = report.warnings
        self.failures = report.failures
    }

    private static func hostKindName(_ kind: HostKind) -> String {
        switch kind {
        case .sunshine:
            return "sunshine"
        case .apollo:
            return "apollo"
        case .unknown:
            return "unknown"
        }
    }
}

private struct HostPayload: Codable {
    let address: String
    let port: Int
    let securePort: Int?

    init(endpoint: HostEndpoint) {
        self.address = endpoint.address
        self.port = endpoint.port
        self.securePort = endpoint.securePort
    }
}

private struct CapturedFramePlaneMetadata: Codable, Sendable {
    let index: Int
    let width: Int
    let height: Int
    let bytesPerRow: Int
}

private struct CapturedFrameMetadata: Codable, Sendable {
    let fileName: String
    let timestamp: UInt64
    let width: Int
    let height: Int
    let pixelFormat: UInt32
    let pixelFormatName: String
    let planeCount: Int
    let planes: [CapturedFramePlaneMetadata]
    let attachments: [String: String]
}

private enum ImageDeltaAnalyzer {
    static func measure(referenceFiles: [URL], metalFiles: [URL]) throws -> ImageDeltaSummary? {
        let pairCount = min(referenceFiles.count, metalFiles.count)
        guard pairCount > 0 else {
            return nil
        }

        return try measurePairs((0..<pairCount).map { (referenceFiles[$0], metalFiles[$0]) })
    }

    static func measure(referenceFile: URL, comparisonFile: URL) throws -> ImageDeltaSummary? {
        try measurePairs([(referenceFile, comparisonFile)])
    }

    static func measureRegions(
        referenceFile: URL,
        comparisonFile: URL,
        requests: [ImageDeltaRegionRequest]
    ) throws -> [ImageDeltaRegionSummary] {
        guard !requests.isEmpty else {
            return []
        }

        let reference = try loadBGRA(referenceFile)
        let comparison = try loadBGRA(comparisonFile)
        guard reference.width == comparison.width, reference.height == comparison.height else {
            throw MoonlightError(
                .unsupportedOperation,
                message: "Cannot compare image regions with different dimensions: \(referenceFile.lastPathComponent) and \(comparisonFile.lastPathComponent)"
            )
        }

        return requests.map { request in
            measureRegion(reference: reference, comparison: comparison, request: request)
        }
    }

    static func detectInputVisualTarget(
        file: URL,
        expectedFrame: InputVisualExpectedFrame
    ) throws -> InputVisualTargetPresenceSummary {
        let image = try loadBGRA(file)
        let frameMinX = Int((Double(image.width) * expectedFrame.minX).rounded(.down))
        let frameMinY = Int((Double(image.height) * expectedFrame.minY).rounded(.down))
        let frameWidth = max(1, Int((Double(image.width) * expectedFrame.width).rounded(.down)))
        let frameHeight = max(1, Int((Double(image.height) * expectedFrame.height).rounded(.down)))
        let sentinelWidth = min(frameWidth, 320)
        let sentinelHeight = min(frameHeight, 64)
        let colors: [(r: UInt8, g: UInt8, b: UInt8)] = [
            (255, 0, 255),
            (0, 255, 0),
            (0, 102, 255),
            (255, 255, 255),
        ]
        let segmentWidth = max(1, sentinelWidth / colors.count)
        let ratios = colors.enumerated().map { index, color in
            let minX = frameMinX + index * segmentWidth + 8
            let maxX = min(frameMinX + (index + 1) * segmentWidth - 9, image.width - 1)
            let minY = frameMinY + 8
            let maxY = min(frameMinY + sentinelHeight - 9, image.height - 1)
            guard minX <= maxX, minY <= maxY else {
                return 0.0
            }
            return colorMatchRatio(
                image: image,
                minX: minX,
                maxX: maxX,
                minY: minY,
                maxY: maxY,
                color: color,
                tolerance: 48
            )
        }

        return InputVisualTargetPresenceSummary(
            detected: ratios.count == colors.count && ratios.allSatisfy { $0 >= 0.72 },
            sentinelRatios: ratios
        )
    }

    private static func measurePairs(_ filePairs: [(URL, URL)]) throws -> ImageDeltaSummary? {
        var totalSamples = 0
        var absoluteSum = 0.0
        var squaredSum = 0.0
        var maxDelta: UInt8 = 0
        var changedPixels = 0
        var totalPixels = 0
        var minChangedX = Int.max
        var minChangedY = Int.max
        var maxChangedX = 0
        var maxChangedY = 0

        for (referenceFile, comparisonFile) in filePairs {
            let reference = try loadBGRA(referenceFile)
            let comparison = try loadBGRA(comparisonFile)
            guard reference.width == comparison.width, reference.height == comparison.height else {
                throw MoonlightError(
                    .unsupportedOperation,
                    message: "Cannot compare images with different dimensions: \(referenceFile.lastPathComponent) and \(comparisonFile.lastPathComponent)"
                )
            }

            let sampleCount = min(reference.data.count, comparison.data.count)
            var offset = 0
            var pixelIndex = 0
            while offset + 2 < sampleCount {
                // Compare B, G, and R. Alpha is ignored because both capture paths
                // write opaque diagnostic PNGs.
                var pixelMaxDelta: UInt8 = 0
                for channel in 0..<3 {
                    let delta = UInt8(abs(Int(reference.data[offset + channel]) - Int(comparison.data[offset + channel])))
                    absoluteSum += Double(delta)
                    squaredSum += Double(delta) * Double(delta)
                    maxDelta = max(maxDelta, delta)
                    pixelMaxDelta = max(pixelMaxDelta, delta)
                    totalSamples += 1
                }
                if pixelMaxDelta >= 12 {
                    changedPixels += 1
                    let x = pixelIndex % reference.width
                    let y = pixelIndex / reference.width
                    minChangedX = min(minChangedX, x)
                    minChangedY = min(minChangedY, y)
                    maxChangedX = max(maxChangedX, x)
                    maxChangedY = max(maxChangedY, y)
                }
                totalPixels += 1
                pixelIndex += 1
                offset += 4
            }
        }

        guard totalSamples > 0 else {
            return nil
        }

        return ImageDeltaSummary(
            framePairs: filePairs.count,
            meanRGBDelta: absoluteSum / Double(totalSamples),
            rmsRGBDelta: sqrt(squaredSum / Double(totalSamples)),
            maxRGBDelta: maxDelta,
            changedPixels: changedPixels,
            totalPixels: totalPixels,
            changedPixelRatio: totalPixels == 0 ? 0 : Double(changedPixels) / Double(totalPixels),
            changedBounds: changedPixels == 0 ? nil : ImageDeltaBounds(
                minX: minChangedX,
                minY: minChangedY,
                maxX: maxChangedX,
                maxY: maxChangedY
            )
        )
    }

    private static func measureRegion(
        reference: (width: Int, height: Int, data: Data),
        comparison: (width: Int, height: Int, data: Data),
        request: ImageDeltaRegionRequest
    ) -> ImageDeltaRegionSummary {
        let centerX = Int((Double(reference.width - 1) * request.centerXRatio).rounded())
        let centerY = Int((Double(reference.height - 1) * request.centerYRatio).rounded())
        let minX = max(0, centerX - request.halfExtent)
        let maxX = min(reference.width - 1, centerX + request.halfExtent)
        let minY = max(0, centerY - request.halfExtent)
        let maxY = min(reference.height - 1, centerY + request.halfExtent)
        var changedPixels = 0
        var totalPixels = 0

        for y in minY...maxY {
            for x in minX...maxX {
                let offset = ((y * reference.width) + x) * 4
                guard offset + 2 < reference.data.count, offset + 2 < comparison.data.count else {
                    continue
                }
                var pixelMaxDelta: UInt8 = 0
                for channel in 0..<3 {
                    let delta = UInt8(abs(Int(reference.data[offset + channel]) - Int(comparison.data[offset + channel])))
                    pixelMaxDelta = max(pixelMaxDelta, delta)
                }
                if pixelMaxDelta >= 12 {
                    changedPixels += 1
                }
                totalPixels += 1
            }
        }

        return ImageDeltaRegionSummary(
            name: request.name,
            bounds: ImageDeltaBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY),
            changedPixels: changedPixels,
            totalPixels: totalPixels,
            changedPixelRatio: totalPixels == 0 ? 0 : Double(changedPixels) / Double(totalPixels)
        )
    }

    private static func colorMatchRatio(
        image: (width: Int, height: Int, data: Data),
        minX: Int,
        maxX: Int,
        minY: Int,
        maxY: Int,
        color: (r: UInt8, g: UInt8, b: UInt8),
        tolerance: UInt8
    ) -> Double {
        var matchedPixels = 0
        var totalPixels = 0

        for y in minY...maxY {
            for x in minX...maxX {
                let offset = ((y * image.width) + x) * 4
                guard offset + 2 < image.data.count else {
                    continue
                }
                let b = image.data[offset]
                let g = image.data[offset + 1]
                let r = image.data[offset + 2]
                if abs(Int(r) - Int(color.r)) <= Int(tolerance),
                   abs(Int(g) - Int(color.g)) <= Int(tolerance),
                   abs(Int(b) - Int(color.b)) <= Int(tolerance) {
                    matchedPixels += 1
                }
                totalPixels += 1
            }
        }

        return totalPixels == 0 ? 0 : Double(matchedPixels) / Double(totalPixels)
    }

    private static func loadBGRA(_ url: URL) throws -> (width: Int, height: Int, data: Data) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to load image for comparison: \(url.path)")
        }

        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var data = Data(repeating: 0, count: bytesPerRow * height)
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(.init(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        try data.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: bitmapInfo.rawValue
                  )
            else {
                throw MoonlightError(.unsupportedOperation, message: "Failed to create image comparison context")
            }

            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        return (width, height, data)
    }
}

private actor MetricsRecorder {
    private var latest = SessionMetricsSnapshot()

    func update(_ snapshot: SessionMetricsSnapshot) {
        latest = snapshot
    }

    func snapshot() -> SessionMetricsSnapshot {
        latest
    }
}

private actor WarningRecorder {
    private var warnings: [String] = []

    func append(_ warning: String) {
        warnings.append(warning)
    }

    func snapshot() -> [String] {
        warnings
    }
}

private actor HDRModeRecorder {
    private var latest: HDRModeCaptureState?

    func update(_ update: HDRModeUpdate) {
        latest = HDRModeCaptureState(update: update)
    }

    func snapshot() -> HDRModeCaptureState? {
        latest
    }
}

private actor FrameCaptureRenderer: FrameRenderer {
    private let outputDirectory: URL
    private let frameLimit: Int
    private let context = CIContext()
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var preparedFormat: VideoFormat?
    private var capturedFiles: [URL] = []
    private var metadataRecords: [CapturedFrameMetadata] = []
    private var loggedPixelBufferFormat = false

    init(outputDirectory: URL, frameLimit: Int) {
        self.outputDirectory = outputDirectory
        self.frameLimit = frameLimit
    }

    func prepare(format: VideoFormat) async throws {
        preparedFormat = format
    }

    func render(_ frame: DecodedVideoFrame) async {
        guard capturedFiles.count < frameLimit else {
            return
        }
        guard let pixelBuffer = frame.pixelBuffer?.pixelBuffer else {
            return
        }

        if !loggedPixelBufferFormat {
            loggedPixelBufferFormat = true
            let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
            let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
            fputs(
                "swift-moonlight-capture frame trace: pixelFormat=\(fourCCString(format)) planeCount=\(planeCount)\n",
                stderr
            )
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)

        do {
            guard let cgImage = context.createCGImage(image, from: rect) else {
                throw MoonlightError(.unsupportedOperation, message: "Failed to create CGImage from decoded frame")
            }

            let fileURL = outputDirectory.appending(path: fileName(for: frame, index: capturedFiles.count + 1))
            guard let destination = CGImageDestinationCreateWithURL(fileURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw MoonlightError(.unsupportedOperation, message: "Failed to create image destination")
            }
            CGImageDestinationAddImage(destination, cgImage, [
                kCGImageDestinationLossyCompressionQuality: 1.0
            ] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw MoonlightError(.unsupportedOperation, message: "Failed to finalize image destination")
            }

            capturedFiles.append(fileURL)
            metadataRecords.append(makeMetadata(for: pixelBuffer, frame: frame, fileURL: fileURL))
        } catch {
            fputs("swift-moonlight-capture renderer warning: \(error)\n", stderr)
        }
    }

    func teardown() async {}

    func waitForCapture(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if capturedFiles.count >= frameLimit {
                return true
            }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return capturedFiles.count >= frameLimit
            }
        }
        return capturedFiles.count >= frameLimit
    }

    func snapshotFiles() -> [URL] {
        capturedFiles
    }

    func writeMetadataFile() -> URL? {
        guard !metadataRecords.isEmpty else {
            return nil
        }

        let fileURL = outputDirectory.appending(path: "frame-metadata.json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(metadataRecords)
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            fputs("swift-moonlight-capture metadata warning: \(error)\n", stderr)
            return nil
        }
    }

    func snapshotMetadataRecords() -> [CapturedFrameMetadata] {
        metadataRecords
    }

    private func fileName(for frame: DecodedVideoFrame, index: Int) -> String {
        let formatSuffix: String
        if let preparedFormat {
            switch preparedFormat.codec {
            case .hevc:
                formatSuffix = "hevc"
            case .h264:
                formatSuffix = "h264"
            case .av1:
                formatSuffix = "av1"
            }
        } else {
            formatSuffix = "unknown"
        }
        let width = Int(frame.dimensions.width.rounded())
        let height = Int(frame.dimensions.height.rounded())
        return String(format: "frame-%04d-%@-%dx%d-ts-%llu.png", index, formatSuffix, width, height, frame.timestamp)
    }

    private func makeMetadata(
        for pixelBuffer: CVPixelBuffer,
        frame: DecodedVideoFrame,
        fileURL: URL
    ) -> CapturedFrameMetadata {
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        let planes: [CapturedFramePlaneMetadata]
        if planeCount == 0 {
            planes = [
                CapturedFramePlaneMetadata(
                    index: 0,
                    width: CVPixelBufferGetWidth(pixelBuffer),
                    height: CVPixelBufferGetHeight(pixelBuffer),
                    bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer)
                )
            ]
        } else {
            planes = (0..<planeCount).map { index in
                CapturedFramePlaneMetadata(
                    index: index,
                    width: CVPixelBufferGetWidthOfPlane(pixelBuffer, index),
                    height: CVPixelBufferGetHeightOfPlane(pixelBuffer, index),
                    bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, index)
                )
            }
        }
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        return CapturedFrameMetadata(
            fileName: fileURL.lastPathComponent,
            timestamp: frame.timestamp,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            pixelFormat: UInt32(pixelFormat),
            pixelFormatName: fourCCString(pixelFormat),
            planeCount: planeCount,
            planes: planes,
            attachments: colorAttachments(from: pixelBuffer)
        )
    }

    private func colorAttachments(from pixelBuffer: CVPixelBuffer) -> [String: String] {
        [
            "colorPrimaries": attachmentDescription(kCVImageBufferColorPrimariesKey, from: pixelBuffer),
            "transferFunction": attachmentDescription(kCVImageBufferTransferFunctionKey, from: pixelBuffer),
            "ycbcrMatrix": attachmentDescription(kCVImageBufferYCbCrMatrixKey, from: pixelBuffer),
            "chromaLocationTop": attachmentDescription(kCVImageBufferChromaLocationTopFieldKey, from: pixelBuffer),
            "chromaLocationBottom": attachmentDescription(kCVImageBufferChromaLocationBottomFieldKey, from: pixelBuffer),
            "masteringDisplayColorVolume": attachmentDescription(kCVImageBufferMasteringDisplayColorVolumeKey, from: pixelBuffer),
            "contentLightLevelInfo": attachmentDescription(kCVImageBufferContentLightLevelInfoKey, from: pixelBuffer),
        ].compactMapValues { $0 }
    }

    private func attachmentDescription(_ key: CFString, from pixelBuffer: CVPixelBuffer) -> String? {
        CVBufferCopyAttachment(pixelBuffer, key, nil).map { String(describing: $0) }
    }

    private func fourCCString(_ value: OSType) -> String {
        let scalars: [UnicodeScalar] = [
            UnicodeScalar((value >> 24) & 0xFF),
            UnicodeScalar((value >> 16) & 0xFF),
            UnicodeScalar((value >> 8) & 0xFF),
            UnicodeScalar(value & 0xFF),
        ].compactMap { $0 }
        let text = String(String.UnicodeScalarView(scalars))
        if text.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 && $0.value < 0x7F }) {
            return text
        }
        return String(format: "0x%08X", value)
    }
}

private actor FanoutRenderer: FrameRenderer {
    private let renderers: [any FrameRenderer]

    init(renderers: [any FrameRenderer]) {
        self.renderers = renderers
    }

    func prepare(format: VideoFormat) async throws {
        for renderer in renderers {
            try await renderer.prepare(format: format)
        }
    }

    func render(_ frame: DecodedVideoFrame) async {
        for renderer in renderers {
            await renderer.render(frame)
        }
    }

    func teardown() async {
        for renderer in renderers {
            await renderer.teardown()
        }
    }
}

#if canImport(Metal)
private actor MetalReadbackTarget: MetalFrameTarget {
    private let device: MTLDevice
    private let outputDirectory: URL
    private let frameLimit: Int
    private let commandQueue: MTLCommandQueue
    private let vertexBuffer: MTLBuffer
    private let rgbPipelineState: MTLRenderPipelineState
    private let biPlanarPipelineState: MTLRenderPipelineState
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var capturedFiles: [URL] = []
    private var preparedFormat: VideoFormat?

    init(device: MTLDevice, outputDirectory: URL, frameLimit: Int) throws {
        self.device = device
        self.outputDirectory = outputDirectory
        self.frameLimit = frameLimit

        guard let commandQueue = device.makeCommandQueue() else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to create Metal readback command queue")
        }
        self.commandQueue = commandQueue

        let vertices: [Float] = [
            -1, -1, 0, 1,
             3, -1, 2, 1,
            -1,  3, 0, -1
        ]
        guard let vertexBuffer = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<Float>.stride) else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to create Metal readback vertex buffer")
        }
        self.vertexBuffer = vertexBuffer

        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        self.rgbPipelineState = try device.makeRenderPipelineState(
            descriptor: Self.makePipelineDescriptor(library: library, fragmentFunction: "fragmentRGB")
        )
        self.biPlanarPipelineState = try device.makeRenderPipelineState(
            descriptor: Self.makePipelineDescriptor(library: library, fragmentFunction: "fragmentBiPlanar")
        )
    }

    func prepare(format: VideoFormat) async throws {
        preparedFormat = format
    }

    func present(_ frame: MetalPresentedFrame) async {
        guard capturedFiles.count < frameLimit else {
            return
        }

        let width = max(Int(frame.dimensions.width.rounded()), 1)
        let height = max(Int(frame.dimensions.height.rounded()), 1)

        do {
            let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            textureDescriptor.usage = [.renderTarget]
            textureDescriptor.storageMode = .shared
            guard let outputTexture = device.makeTexture(descriptor: textureDescriptor) else {
                throw MoonlightError(.unsupportedOperation, message: "Failed to create Metal readback texture")
            }
            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                throw MoonlightError(.unsupportedOperation, message: "Failed to create Metal readback command buffer")
            }

            let passDescriptor = MTLRenderPassDescriptor()
            passDescriptor.colorAttachments[0].texture = outputTexture
            passDescriptor.colorAttachments[0].loadAction = .clear
            passDescriptor.colorAttachments[0].storeAction = .store
            passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
                throw MoonlightError(.unsupportedOperation, message: "Failed to create Metal readback encoder")
            }

            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            switch frame.textures {
            case .rgb(let texture):
                encoder.setRenderPipelineState(rgbPipelineState)
                encoder.setFragmentTexture(texture, index: 0)
            case .biPlanar(let luma, let chroma):
                encoder.setRenderPipelineState(biPlanarPipelineState)
                encoder.setFragmentTexture(luma, index: 0)
                encoder.setFragmentTexture(chroma, index: 1)
                var conversion = frame.colorConversion.makeCaptureShaderUniform()
                encoder.setFragmentBytes(
                    &conversion,
                    length: MemoryLayout<CaptureColorConversionUniform>.stride,
                    index: 0
                )
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()

            await withCheckedContinuation { continuation in
                commandBuffer.addCompletedHandler { _ in
                    continuation.resume()
                }
                commandBuffer.commit()
            }

            let bytesPerRow = width * 4
            var data = Data(repeating: 0, count: bytesPerRow * height)
            data.withUnsafeMutableBytes { outputBytes in
                guard let baseAddress = outputBytes.baseAddress else {
                    return
                }
                outputTexture.getBytes(
                    baseAddress,
                    bytesPerRow: bytesPerRow,
                    from: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0
                )
            }

            let fileURL = outputDirectory.appending(path: fileName(for: frame, index: capturedFiles.count + 1))
            try Self.writeBGRAImage(
                data: data,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                colorSpace: colorSpace,
                destinationURL: fileURL
            )
            capturedFiles.append(fileURL)
        } catch {
            fputs("swift-moonlight-capture metal warning: \(error)\n", stderr)
        }
    }

    func teardown() async {}

    func snapshotFiles() -> [URL] {
        capturedFiles
    }

    private func fileName(for frame: MetalPresentedFrame, index: Int) -> String {
        let formatSuffix: String
        if let preparedFormat {
            switch preparedFormat.codec {
            case .hevc:
                formatSuffix = "hevc"
            case .h264:
                formatSuffix = "h264"
            case .av1:
                formatSuffix = "av1"
            }
        } else {
            formatSuffix = "unknown"
        }
        let width = Int(frame.dimensions.width.rounded())
        let height = Int(frame.dimensions.height.rounded())
        return String(format: "metal-frame-%04d-%@-%dx%d-ts-%llu.png", index, formatSuffix, width, height, frame.timestamp)
    }

    private static func makePipelineDescriptor(
        library: MTLLibrary,
        fragmentFunction: String
    ) -> MTLRenderPipelineDescriptor {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.vertexFunction = library.makeFunction(name: "vertexMain")
        descriptor.fragmentFunction = library.makeFunction(name: fragmentFunction)
        return descriptor
    }

    private static func writeBGRAImage(
        data: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        colorSpace: CGColorSpace,
        destinationURL: URL
    ) throws {
        let provider = CGDataProvider(data: data as CFData)
        guard let provider else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to create Metal readback provider")
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(.init(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to create Metal readback image")
        }
        guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to create Metal readback destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to finalize Metal readback image")
        }
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
    };

    struct ColorConversionUniform {
        float4 offsets;
        float4 scales;
        float4 matrixR;
        float4 matrixG;
        float4 matrixB;
        uint transferFunction;
        uint ycbcrMatrix;
        uint padding0;
        uint padding1;
    };

    vertex VertexOut vertexMain(uint vertexID [[vertex_id]], const device float4* vertices [[buffer(0)]]) {
        VertexOut out;
        float4 entry = vertices[vertexID];
        out.position = float4(entry.xy, 0.0, 1.0);
        out.texCoord = entry.zw;
        return out;
    }

    fragment float4 fragmentRGB(VertexOut in [[stage_in]], texture2d<float> colorTexture [[texture(0)]]) {
        constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
        return colorTexture.sample(textureSampler, in.texCoord);
    }

    float3 linearToSRGB(float3 linear) {
        linear = max(linear, float3(0.0));
        float3 low = linear * 12.92;
        float3 high = 1.055 * pow(linear, float3(1.0 / 2.4)) - 0.055;
        return select(high, low, linear <= float3(0.0031308));
    }

    float3 bt2020LinearToBT709Linear(float3 rgb) {
        // Match the app renderer: HDR decode is BT.2020, while PNG readback is SDR BT.709.
        return float3(
            dot(float3(1.6605, -0.5876, -0.0728), rgb),
            dot(float3(-0.1246, 1.1329, -0.0083), rgb),
            dot(float3(-0.0182, -0.1006, 1.1187), rgb)
        );
    }

    float3 toneMapHDRToSDR(float3 nits) {
        // Avoid diagnostic PNGs that look blown out just because highlights exceed SDR white.
        float3 reference = max(nits / 203.0, float3(0.0));
        float3 linearRegion = reference * 0.78;
        float3 shoulder = 0.78 + 0.22 * (1.0 - exp(-(reference - 1.0) * 0.35));
        return min(select(shoulder, linearRegion, reference <= float3(1.0)), float3(1.0));
    }

    float3 pqToSRGB(float3 pq, uint ycbcrMatrix) {
        constexpr float m1 = 2610.0 / 16384.0;
        constexpr float m2 = 2523.0 / 32.0;
        constexpr float c1 = 3424.0 / 4096.0;
        constexpr float c2 = 2413.0 / 128.0;
        constexpr float c3 = 2392.0 / 128.0;
        pq = clamp(pq, float3(0.0), float3(1.0));
        float3 p = pow(pq, float3(1.0 / m2));
        float3 numerator = max(p - c1, float3(0.0));
        float3 denominator = max(c2 - c3 * p, float3(0.000001));
        float3 nits = pow(numerator / denominator, float3(1.0 / m1)) * 10000.0;
        if (ycbcrMatrix == 1) {
            nits = bt2020LinearToBT709Linear(nits);
        }
        return linearToSRGB(toneMapHDRToSDR(nits));
    }

    float3 hlgToSRGB(float3 hlg, uint ycbcrMatrix) {
        constexpr float a = 0.17883277;
        constexpr float b = 0.28466892;
        constexpr float c = 0.55991073;
        hlg = clamp(hlg, float3(0.0), float3(1.0));
        float3 low = (hlg * hlg) / 3.0;
        float3 high = (exp((hlg - c) / a) + b) / 12.0;
        float3 sceneLinear = select(high, low, hlg <= float3(0.5));
        float3 nits = sceneLinear * 1000.0;
        if (ycbcrMatrix == 1) {
            nits = bt2020LinearToBT709Linear(nits);
        }
        return linearToSRGB(toneMapHDRToSDR(nits));
    }

    fragment float4 fragmentBiPlanar(
        VertexOut in [[stage_in]],
        texture2d<float> lumaTexture [[texture(0)]],
        texture2d<float> chromaTexture [[texture(1)]],
        constant ColorConversionUniform& conversion [[buffer(0)]]
    ) {
        constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
        float y = (lumaTexture.sample(textureSampler, in.texCoord).r - conversion.offsets.x) * conversion.scales.x;
        float2 cbcr = (chromaTexture.sample(textureSampler, in.texCoord).rg - conversion.offsets.yz) * conversion.scales.yz;
        float3 ycbcr = float3(y, cbcr.x, cbcr.y);

        float3 rgb = float3(
            dot(conversion.matrixR.xyz, ycbcr),
            dot(conversion.matrixG.xyz, ycbcr),
            dot(conversion.matrixB.xyz, ycbcr)
        );

        if (conversion.transferFunction == 1) {
            rgb = pqToSRGB(rgb, conversion.ycbcrMatrix);
        } else if (conversion.transferFunction == 2) {
            rgb = hlgToSRGB(rgb, conversion.ycbcrMatrix);
        }

        return float4(saturate(rgb), 1.0);
    }
    """
}

private struct CaptureColorConversionUniform {
    var offsets: SIMD4<Float>
    var scales: SIMD4<Float>
    var matrixR: SIMD4<Float>
    var matrixG: SIMD4<Float>
    var matrixB: SIMD4<Float>
    var transferFunction: UInt32
    var ycbcrMatrix: UInt32
    var padding0: UInt32 = 0
    var padding1: UInt32 = 0
}

private extension MetalColorConversion {
    func makeCaptureShaderUniform() -> CaptureColorConversionUniform {
        let maxCodeValue: Float = componentBitDepth == 10 ? 1023 : 255
        let videoRange = ycbcrRange == .video

        let yOffset: Float
        let yScale: Float
        let chromaOffset: Float
        let chromaScale: Float
        if videoRange {
            if componentBitDepth == 10 {
                yOffset = 64 / maxCodeValue
                yScale = maxCodeValue / (940 - 64)
                chromaOffset = 512 / maxCodeValue
                chromaScale = maxCodeValue / (960 - 64)
            } else {
                yOffset = 16 / maxCodeValue
                yScale = maxCodeValue / (235 - 16)
                chromaOffset = 128 / maxCodeValue
                chromaScale = maxCodeValue / (240 - 16)
            }
        } else {
            yOffset = 0
            yScale = 1
            chromaOffset = 0.5
            chromaScale = 1
        }

        let rows: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
        switch ycbcrMatrix {
        case .bt601:
            rows = (
                SIMD4<Float>(1.0, 0.0, 1.4020, 0.0),
                SIMD4<Float>(1.0, -0.344136, -0.714136, 0.0),
                SIMD4<Float>(1.0, 1.7720, 0.0, 0.0)
            )
        case .bt709:
            rows = (
                SIMD4<Float>(1.0, 0.0, 1.5748, 0.0),
                SIMD4<Float>(1.0, -0.187324, -0.468124, 0.0),
                SIMD4<Float>(1.0, 1.8556, 0.0, 0.0)
            )
        case .bt2020:
            rows = (
                SIMD4<Float>(1.0, 0.0, 1.4746, 0.0),
                SIMD4<Float>(1.0, -0.164553, -0.571353, 0.0),
                SIMD4<Float>(1.0, 1.8814, 0.0, 0.0)
            )
        }

        return CaptureColorConversionUniform(
            offsets: SIMD4<Float>(yOffset, chromaOffset, chromaOffset, 0),
            scales: SIMD4<Float>(yScale, chromaScale, chromaScale, 1),
            matrixR: rows.0,
            matrixG: rows.1,
            matrixB: rows.2,
            transferFunction: transferFunction.rawValue,
            ycbcrMatrix: ycbcrMatrix.rawValue
        )
    }
}
#endif

private actor InspectingVideoDecoder: VideoDecoder {
    private let wrapped: any VideoDecoder
    private let maxLoggedFrames = 5
    private var loggedFrames = 0

    init(wrapped: any VideoDecoder) {
        self.wrapped = wrapped
    }

    func configure(format: VideoFormat) async throws {
        fputs(
            "swift-moonlight-capture decode trace: configured codec=\(codecName(format.codec)) " +
            "dimensions=\(Int(format.dimensions.width))x\(Int(format.dimensions.height))\n",
            stderr
        )
        try await wrapped.configure(format: format)
    }

    func decode(_ frame: EncodedVideoFrame) async throws -> [DecodedVideoFrame] {
        let shouldLogThisFrame = loggedFrames < maxLoggedFrames
        if loggedFrames < maxLoggedFrames {
            loggedFrames += 1
            let parameterSets = frame.parameterSets.isEmpty
                ? AnnexBBitstream.codecParameterSets(from: frame.payload, codec: frame.codec)
                : frame.parameterSets
            let nalUnits = AnnexBBitstream.splitNALUnits(in: frame.payload)
            let nalTypes = nalUnits.prefix(8).map { nalTypeName(for: $0, codec: frame.codec) }.joined(separator: ",")
            let parameterSetSizes = parameterSets.map(\.count).map(String.init).joined(separator: ",")
            let prefixHex = hexString(Data(frame.payload.prefix(32)))
            fputs(
                "swift-moonlight-capture decode trace: " +
                "frame=\(loggedFrames) ts=\(frame.timestamp) key=\(frame.isKeyFrame) " +
                "codec=\(codecName(frame.codec)) payloadBytes=\(frame.payload.count) " +
                "nalUnits=\(nalUnits.count) nalTypes=[\(nalTypes)] " +
                "parameterSets=\(parameterSets.count) parameterSetSizes=[\(parameterSetSizes)] " +
                "prefix=\(prefixHex)\n",
                stderr
            )
        }

        let decoded = try await wrapped.decode(frame)
        if shouldLogThisFrame {
            fputs(
                "swift-moonlight-capture decode trace: " +
                "frame=\(loggedFrames) decodedOutputs=\(decoded.count)\n",
                stderr
            )
        }
        return decoded
    }

    func flush() async throws -> [DecodedVideoFrame] {
        try await wrapped.flush()
    }

    private func codecName(_ codec: VideoCodec) -> String {
        switch codec {
        case .hevc:
            return "hevc"
        case .h264:
            return "h264"
        case .av1:
            return "av1"
        }
    }

    private func nalTypeName(for unit: Data, codec: VideoCodec) -> String {
        guard let first = unit.first else {
            return "empty"
        }

        switch codec {
        case .hevc:
            let type = Int((first & 0x7E) >> 1)
            return "hevc:\(type)"
        case .h264:
            return "h264:\(Int(first & 0x1F))"
        case .av1:
            return "av1"
        }
    }

    private func hexString(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }
}

private actor WAVCaptureAudioSink: AudioSink {
    private let fileURL: URL
    private var preparedFormat: AudioFormat?
    private var pcmData = Data()

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func prepare(format: AudioFormat) async throws {
        preparedFormat = format
    }

    func play(_ buffer: PCMBuffer) async {
        if preparedFormat == nil {
            preparedFormat = AudioFormat(sampleRate: buffer.sampleRate, channelCount: buffer.channelCount)
        }
        pcmData.append(buffer.data)
    }

    func teardown() async {
        guard let preparedFormat, !pcmData.isEmpty else {
            return
        }

        do {
            try WAVFileWriter.writePCM16LE(
                fileURL: fileURL,
                format: preparedFormat,
                pcmData: pcmData
            )
        } catch {
            fputs("swift-moonlight-capture audio warning: \(error)\n", stderr)
        }
    }

    func snapshot() -> (fileURL: URL?, bytes: Int) {
        let fileURL = pcmData.isEmpty ? nil : fileURL
        return (fileURL, pcmData.count)
    }
}

private enum WAVFileWriter {
    static func writePCM16LE(fileURL: URL, format: AudioFormat, pcmData: Data) throws {
        let bitsPerSample = 16
        let blockAlign = UInt16(format.channelCount * bitsPerSample / 8)
        let byteRate = UInt32(format.sampleRate) * UInt32(blockAlign)
        let dataSize = UInt32(pcmData.count)
        let riffSize = 36 + dataSize

        var fileData = Data()
        fileData.append("RIFF".data(using: .ascii)!)
        fileData.appendLE(riffSize)
        fileData.append("WAVE".data(using: .ascii)!)
        fileData.append("fmt ".data(using: .ascii)!)
        fileData.appendLE(UInt32(16))
        fileData.appendLE(UInt16(1))
        fileData.appendLE(UInt16(format.channelCount))
        fileData.appendLE(UInt32(format.sampleRate))
        fileData.appendLE(byteRate)
        fileData.appendLE(blockAlign)
        fileData.appendLE(UInt16(bitsPerSample))
        fileData.append("data".data(using: .ascii)!)
        fileData.appendLE(dataSize)
        fileData.append(pcmData)
        try fileData.write(to: fileURL, options: .atomic)
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 0))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 0))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}

private actor InspectingAudioDecoder: AudioDecoder {
    private let wrapped: any AudioDecoder
    private let maxLoggedPackets = 12
    private var loggedPackets = 0
    private var baselineTOC: UInt8?

    init(wrapped: any AudioDecoder) {
        self.wrapped = wrapped
    }

    func configure(format: AudioFormat) async throws {
        fputs(
            "swift-moonlight-capture audio trace: configured sampleRate=\(format.sampleRate) " +
            "channels=\(format.channelCount)\n",
            stderr
        )
        try await wrapped.configure(format: format)
    }

    func decode(_ packet: EncodedAudioPacket) async throws -> PCMBuffer {
        let packetIndex: Int?
        if loggedPackets < maxLoggedPackets {
            loggedPackets += 1
            packetIndex = loggedPackets
            let prefix = hexString(Data(packet.payload.prefix(16)))
            let tocString: String
            if let toc = packet.payload.first {
                if let baselineTOC, baselineTOC != toc {
                    fputs(
                        "swift-moonlight-capture audio trace: toc changed baseline=\(String(format: "%02X", baselineTOC)) " +
                        "current=\(String(format: "%02X", toc)) packet=\(packetIndex!)\n",
                        stderr
                    )
                } else if baselineTOC == nil {
                    baselineTOC = toc
                }
                tocString = String(format: "%02X", toc)
            } else {
                tocString = ""
            }
            fputs(
                "swift-moonlight-capture audio trace: " +
                "packet=\(packetIndex!) ts=\(packet.timestamp) concealment=\(packet.isConcealment) " +
                "payloadBytes=\(packet.payload.count) toc=\(tocString) prefix=\(prefix)\n",
                stderr
            )
        } else {
            packetIndex = nil
        }

        let buffer = try await wrapped.decode(packet)
        if let packetIndex {
            fputs(
                "swift-moonlight-capture audio trace: " +
                "packet=\(packetIndex) decodedFrames=\(buffer.frameCount) pcmBytes=\(buffer.data.count)\n",
                stderr
            )
        }
        return buffer
    }

    private func hexString(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }
}

private struct HeadlessCaptureRunner {
    let configuration: CaptureConfiguration

    func run() async throws -> CaptureReport {
        let clientConfiguration = try ProductionClientFactory.configuration(
            storageDirectory: configuration.storageDirectory,
            enableDiscovery: false
        )
        let client = MoonlightClient(configuration: clientConfiguration)

        let storedHosts = try await client.discoverHosts()
        let host = try await selectHost(from: storedHosts, client: client)
        let refreshedHost = try await client.refreshHost(host.id)
        guard refreshedHost.pairingState.isPaired else {
            throw MoonlightError(.hostNotPaired, message: "Selected host is not paired")
        }

        let apps = try await client.fetchApps(hostID: refreshedHost.id)
        let appID = selectAppID(from: apps)
        if configuration.cancelBeforeLaunch {
            try? await client.cancelCurrentApp(hostID: refreshedHost.id)
            try? await Task.sleep(for: .milliseconds(500))
        }
        let session = try await client.openSession(
            hostID: refreshedHost.id,
            appID: appID,
            configuration: configuration.streamConfiguration
        )

        let visualTargetOpenFrameBudget = configuration.inputVisualTargetURL == nil ? 0 : 120
        let captureFrameLimit = configuration.frameLimit
            + configuration.inputVisualProbeMode.additionalFrameLimit
            + visualTargetOpenFrameBudget
        let renderer = FrameCaptureRenderer(
            outputDirectory: configuration.outputDirectory,
            frameLimit: captureFrameLimit
        )
#if canImport(Metal)
        let metalTarget: MetalReadbackTarget? = if configuration.disableMetalReadback {
            nil
        } else {
            try MTLCreateSystemDefaultDevice().map {
                try MetalReadbackTarget(
                    device: $0,
                    outputDirectory: configuration.outputDirectory,
                    frameLimit: captureFrameLimit
                )
            }
        }
#else
        let metalTarget: MetalReadbackTarget? = nil
#endif
        let decoder: any VideoDecoder = configuration.traceDecode
            ? InspectingVideoDecoder(wrapped: VideoToolboxDecoder())
            : VideoToolboxDecoder()
        let audioSink = WAVCaptureAudioSink(
            fileURL: configuration.outputDirectory.appending(path: "audio.wav")
        )
#if canImport(Metal)
        let appEquivalentRenderer: (any FrameRenderer)?
        if let metalTarget, let device = MTLCreateSystemDefaultDevice() {
            appEquivalentRenderer = try MetalRenderer(device: device, target: metalTarget)
        } else {
            appEquivalentRenderer = nil
        }
#else
        let appEquivalentRenderer: (any FrameRenderer)? = nil
#endif
        let attachedRenderer: any FrameRenderer
        if let appEquivalentRenderer {
            attachedRenderer = FanoutRenderer(renderers: [renderer, appEquivalentRenderer])
        } else {
            attachedRenderer = renderer
        }
#if canImport(COpus)
        let audioDecoder: any AudioDecoder = configuration.traceAudio
            ? InspectingAudioDecoder(wrapped: OpusDecoder())
            : OpusDecoder()
#else
        let audioDecoder: any AudioDecoder = SilenceAudioDecoder()
#endif
        try await session.attachVideoDecoder(decoder)
        try await session.attachRenderer(attachedRenderer)
        try await session.attachAudioDecoder(audioDecoder)
        try await session.attachAudioSink(audioSink)

        let metricsRecorder = MetricsRecorder()
        let warningRecorder = WarningRecorder()
        let hdrModeRecorder = HDRModeRecorder()
        let metricsStream = await session.metrics
        let eventsStream = await session.events
        let metricsTask = Task {
            for await snapshot in metricsStream {
                await metricsRecorder.update(snapshot)
            }
        }
        let eventTask = Task {
            for await event in eventsStream {
                switch event {
                case .warning(let warning):
                    await warningRecorder.append(warning.message)
                case .hdrModeChanged(let update):
                    await hdrModeRecorder.update(update)
                case .failed(let error):
                    await warningRecorder.append("session failed: \(error.message)")
                default:
                    break
                }
            }
        }

        let preparedRuntime = try await client.prepareRuntime(
            for: session,
            hostID: refreshedHost.id,
            configuration: configuration.runtimeConfiguration
        )

        var runtimeStarted = false
        var runtimeSnapshot = RuntimeObservationSnapshot()
        var inputVisualProbe: InputVisualProbeResult?
        do {
            await preparedRuntime.runtime.start()
            runtimeStarted = true
            try? await session.send(InputEvent.mouse(.relativeMove(dx: 0, dy: 0)))
            try? await session.flushPendingInput()
            if let warning = await openInputVisualTargetIfConfigured(session: session) {
                await warningRecorder.append(warning)
            }
            inputVisualProbe = await runInputVisualProbeIfNeeded(
                session: session,
                renderer: renderer,
                sockets: preparedRuntime.sockets
            )
            runtimeSnapshot = await waitForRequiredSignals(
                renderer: renderer,
                runtime: preparedRuntime.runtime
            )
        }

        if runtimeStarted {
            await preparedRuntime.stop()
        }
        metricsTask.cancel()
        eventTask.cancel()

        try? await client.cancelCurrentApp(hostID: refreshedHost.id)

        let files = await renderer.snapshotFiles()
        let frameMetadata = await renderer.snapshotMetadataRecords()
        let frameMetadataURL = await renderer.writeMetadataFile()
#if canImport(Metal)
        let metalFiles = await metalTarget?.snapshotFiles() ?? []
#else
        let metalFiles: [URL] = []
#endif
        var warnings = await warningRecorder.snapshot()
        let metalReadbackDelta: ImageDeltaSummary?
        do {
            metalReadbackDelta = try ImageDeltaAnalyzer.measure(referenceFiles: files, metalFiles: metalFiles)
        } catch {
            metalReadbackDelta = nil
            warnings.append("Metal readback comparison failed: \(error.localizedDescription)")
        }
        let audioCapture = await audioSink.snapshot()
        let recordedMetrics = await metricsRecorder.snapshot()
        let currentMetrics = await session.currentMetricsSnapshot()
        let metrics = mergedMetrics(
            recorded: recordedMetrics,
            current: currentMetrics,
            runtime: runtimeSnapshot
        )
        let hdrMode = await hdrModeRecorder.snapshot()

        var failures: [String] = []
        if files.isEmpty {
            failures.append("no decoded image files were written")
        }
        if !files.isEmpty, frameMetadataURL == nil {
            failures.append("frame metadata was not written")
        }
        if metrics.videoPacketsObserved == 0, files.isEmpty, metalFiles.isEmpty {
            failures.append("video channel observed no packets")
        }
        if metrics.decodedVideoFrames == 0, files.isEmpty {
            failures.append("decoder produced no frames")
        }
        if metrics.renderedVideoFrames == 0, files.isEmpty, metalFiles.isEmpty {
            failures.append("renderer received no frames")
        }
        if metrics.audioPacketsObserved > 0 && metrics.decodedAudioBuffers == 0 {
            failures.append("audio decoder produced no PCM buffers")
        }
        if metrics.audioPacketsObserved > 0 && audioCapture.bytes == 0 {
            failures.append("audio capture produced no PCM bytes")
        }
        if configuration.requireAudio, metrics.audioPacketsObserved == 0 {
            failures.append("audio was required but the audio channel observed no packets")
            if refreshedHost.kind == .apollo, configuration.streamConfiguration.requestContinuousAudio {
                warnings.append("Apollo reference sources do not handle continuousAudio; use an active host audio source for audio-required capture")
            }
        }
        if metrics.unexpectedDisconnect {
            failures.append("session disconnected unexpectedly")
        }
        if let maxMissingVideoPackets = configuration.maxMissingVideoPackets,
           metrics.missingVideoPackets > maxMissingVideoPackets
        {
            failures.append("missing video packets exceeded \(maxMissingVideoPackets): \(metrics.missingVideoPackets)")
        }
        if let maxVideoDiscontinuities = configuration.maxVideoDiscontinuities,
           metrics.videoDiscontinuityEvents > maxVideoDiscontinuities
        {
            failures.append("video discontinuities exceeded \(maxVideoDiscontinuities): \(metrics.videoDiscontinuityEvents)")
        }
        if let maxRecoverableVideoDecodeFailures = configuration.maxRecoverableVideoDecodeFailures,
           metrics.recoverableVideoDecodeFailures > maxRecoverableVideoDecodeFailures
        {
            failures.append("recoverable video decode failures exceeded \(maxRecoverableVideoDecodeFailures): \(metrics.recoverableVideoDecodeFailures)")
        }
        if configuration.requireInputVisualProbe, configuration.inputVisualProbeMode == .disabled {
            failures.append("input visual probe was required but disabled")
        }
        if let inputVisualProbe, let warning = inputVisualProbe.warning {
            warnings.append(warning)
        }
        if configuration.requireInputVisualProbe, let inputVisualProbe, !inputVisualProbe.passed {
            failures.append("input visual probe did not produce an observable decoded-frame change")
        }
        if configuration.requireInputVisualExpectedRegions {
            if configuration.inputVisualProbeMode != .absolutePointerSweep {
                failures.append("input visual expected-region validation requires the absolute probe mode")
            } else if let inputVisualProbe {
                let threshold = configuration.inputVisualExpectedRegionMinChangedPixelRatio
                let failingRegions = inputVisualProbe.expectedRegions.filter {
                    $0.changedPixelRatio < threshold
                }
                if inputVisualProbe.expectedRegions.isEmpty {
                    failures.append("input visual expected-region validation produced no region measurements")
                } else if !failingRegions.isEmpty {
                    let regions = failingRegions.map(\.name).joined(separator: ",")
                    failures.append("input visual expected regions below \(threshold): \(regions)")
                }
            } else {
                failures.append("input visual expected-region validation was required but the probe did not run")
            }
        }
        let capturedHDRMetadata = frameMetadata.contains(where: Self.frameLooksHDR)
        if configuration.requireHDR, hdrMode?.enabled == false {
            failures.append("HDR was required but host reported HDR mode disabled")
        }
        if configuration.requireHDR, !capturedHDRMetadata {
            failures.append("HDR was required but no captured frame advertised PQ or HLG transfer metadata")
        }
        if let metalReadbackDelta,
           !capturedHDRMetadata,
           metalReadbackDelta.indicatesSDRRegression
        {
            failures.append(
                "Metal readback diverged from decoded SDR PNGs " +
                "(mean \(String(format: "%.2f", metalReadbackDelta.meanRGBDelta)), " +
                "rms \(String(format: "%.2f", metalReadbackDelta.rmsRGBDelta)), " +
                "max \(metalReadbackDelta.maxRGBDelta))"
            )
        }

        return CaptureReport(
            host: refreshedHost.endpoint,
            hostKind: refreshedHost.kind,
            appID: appID,
            outputDirectory: configuration.outputDirectory,
            capturedImages: files.count,
            firstImagePath: files.first?.path,
            lastImagePath: files.last?.path,
            frameMetadataPath: frameMetadataURL?.path,
            capturedMetalImages: metalFiles.count,
            firstMetalImagePath: metalFiles.first?.path,
            lastMetalImagePath: metalFiles.last?.path,
            metalReadbackDelta: metalReadbackDelta,
            hdrMode: hdrMode,
            inputVisualProbe: inputVisualProbe,
            audioWAVPath: audioCapture.fileURL?.path,
            audioBytes: audioCapture.bytes,
            paired: refreshedHost.pairingState.isPaired,
            controlConnected: preparedRuntime.sockets.controlTransport != nil,
            inputConnected: preparedRuntime.sockets.inputTransport != nil,
            metrics: metrics,
            warnings: warnings,
            failures: failures
        )
    }

    private static func frameLooksHDR(_ metadata: CapturedFrameMetadata) -> Bool {
        guard let transfer = metadata.attachments["transferFunction"]?.lowercased() else {
            return false
        }
        return transfer.contains("2084") || transfer.contains("pq") || transfer.contains("hlg") || transfer.contains("2100")
    }

    private func openInputVisualTargetIfConfigured(session: MoonlightSession) async -> String? {
        guard let urlString = configuration.inputVisualTargetURL else {
            return nil
        }

        do {
            try? await session.send(.mouse(.absoluteMove(x: 0.5, y: 0.5)))
            try? await session.flushPendingInput()
            let command = if let helperURL = configuration.inputVisualOpenHelperURL {
                windowsPowerShellVisualTargetCommand(targetURL: urlString, helperURL: helperURL)
            } else {
                urlString
            }
            try await openWindowsRunText(
                command,
                session: session,
                toggleFullScreen: configuration.inputVisualOpenHelperURL == nil
            )
            return nil
        } catch {
            let message = (error as? MoonlightError)?.message ?? error.localizedDescription
            return "input visual target open failed: \(message)"
        }
    }

    private func windowsPowerShellVisualTargetCommand(targetURL: String, helperURL: String) -> String {
        let escapedTarget = targetURL.replacingOccurrences(of: "'", with: "''")
        let escapedHelper = helperURL.replacingOccurrences(of: "'", with: "''")
        return "powershell -NoP -EP Bypass -C \"iex(irm '\(escapedHelper)');o '\(escapedTarget)'\""
    }

    private func openWindowsRunText(
        _ text: String,
        session: MoonlightSession,
        toggleFullScreen: Bool
    ) async throws {
        try await sendKeyDown(.leftCommand, modifiers: [.command], session: session)
        try await sendKeyDown(.r, modifiers: [.command], session: session)
        try await sendKeyUp(.r, modifiers: [.command], session: session)
        try await sendKeyUp(.leftCommand, session: session)
        try await session.flushPendingInput()
        try await Task.sleep(for: .milliseconds(600))

        for chunk in text.utf8ByteLimitedChunks(maxBytes: 30) {
            try await session.send(.keyboard(.text(chunk)))
        }
        try await sendKeyDown(.enter, session: session)
        try await sendKeyUp(.enter, session: session)
        try await session.flushPendingInput()
        if toggleFullScreen {
            try await Task.sleep(for: .milliseconds(1500))
            try await sendKeyDown(.f11, session: session)
            try await sendKeyUp(.f11, session: session)
            try await session.flushPendingInput()
        }
        try await Task.sleep(for: .seconds(3))
    }

    private func sendKeyDown(
        _ keyCode: KeyCode,
        modifiers: KeyModifiers = [],
        session: MoonlightSession
    ) async throws {
        try await session.send(.keyboard(.keyDown(keyCode, modifiers: modifiers)))
    }

    private func sendKeyUp(
        _ keyCode: KeyCode,
        modifiers: KeyModifiers = [],
        session: MoonlightSession
    ) async throws {
        try await session.send(.keyboard(.keyUp(keyCode, modifiers: modifiers)))
    }

    private func runInputVisualProbeIfNeeded(
        session: MoonlightSession,
        renderer: FrameCaptureRenderer,
        sockets: ChannelSocketSet
    ) async -> InputVisualProbeResult? {
        guard configuration.inputVisualProbeMode != .disabled else {
            return nil
        }

        let inputPacketsBefore = await session.currentMetricsSnapshot().inputPacketsSent
        guard sockets.inputTransport != nil else {
            return InputVisualProbeResult(
                mode: configuration.inputVisualProbeMode,
                attempted: false,
                passed: false,
                inputPacketsBefore: inputPacketsBefore,
                inputPacketsAfter: inputPacketsBefore,
                baselineImagePath: nil,
                comparisonImagePath: nil,
                meanRGBDelta: nil,
                rmsRGBDelta: nil,
                maxRGBDelta: nil,
                changedPixels: nil,
                changedPixelRatio: nil,
                changedBounds: nil,
                expectedRegions: [],
                targetPresence: nil,
                warning: "input visual probe skipped because the input transport is not connected"
            )
        }

        var baselineCandidate: (file: URL, targetPresence: InputVisualTargetPresenceSummary?)?
        if configuration.inputVisualTargetURL != nil {
            baselineCandidate = await waitForInputVisualTargetFrame(renderer: renderer, timeout: .seconds(6))
            if baselineCandidate == nil {
                try? await moveActiveWindowAcrossDisplays(session: session)
                baselineCandidate = await waitForInputVisualTargetFrame(renderer: renderer, timeout: .seconds(6))
            }
        } else if await waitForFrameCount(renderer: renderer, count: 1, timeout: configuration.timeout),
                  let file = await renderer.snapshotFiles().last {
            baselineCandidate = (file: file, targetPresence: nil)
        } else {
            baselineCandidate = nil
        }

        guard let baselineCandidate else {
            let latestImage = await renderer.snapshotFiles().last
            let latestPresence: InputVisualTargetPresenceSummary?
            if let latestImage {
                latestPresence = try? ImageDeltaAnalyzer.detectInputVisualTarget(
                    file: latestImage,
                    expectedFrame: configuration.inputVisualExpectedFrame
                )
            } else {
                latestPresence = nil
            }
            return InputVisualProbeResult(
                mode: configuration.inputVisualProbeMode,
                attempted: false,
                passed: false,
                inputPacketsBefore: inputPacketsBefore,
                inputPacketsAfter: inputPacketsBefore,
                baselineImagePath: latestImage?.path,
                comparisonImagePath: nil,
                meanRGBDelta: nil,
                rmsRGBDelta: nil,
                maxRGBDelta: nil,
                changedPixels: nil,
                changedPixelRatio: nil,
                changedBounds: nil,
                expectedRegions: [],
                targetPresence: latestPresence,
                warning: configuration.inputVisualTargetURL == nil
                    ? "input visual probe skipped because no baseline frame was captured"
                    : "input visual probe skipped because the input visual target page was not visible in the stream"
            )
        }
        let baselineImage = baselineCandidate.file
        let baselineTargetPresence = baselineCandidate.targetPresence

        let baselineCount = await renderer.snapshotFiles().count
        let warningPrefix = "input visual probe did not observe decoded-frame motion"
        do {
            var comparisonBaseline = baselineImage
            var comparisonBaselineCount = baselineCount

            switch configuration.inputVisualProbeMode {
            case .disabled:
                break
            case .reversibleRelativeMotion:
                try await session.send(.mouse(.relativeMove(dx: 96, dy: 0)))
                try await session.flushPendingInput()
            case .absolutePointerSweep:
                let expectedFrame = configuration.inputVisualExpectedFrame
                try await session.send(.mouse(.absoluteMove(x: expectedFrame.x(0.25), y: expectedFrame.y(0.5))))
                try await session.flushPendingInput()
                try await clickInputVisualTargetIfConfigured(session: session)
                _ = await waitForFrameCount(
                    renderer: renderer,
                    count: baselineCount + 2,
                    timeout: .seconds(3)
                )
                let firstPositionFiles = await renderer.snapshotFiles()
                comparisonBaseline = firstPositionFiles.dropFirst(baselineCount).last ?? firstPositionFiles.last ?? baselineImage
                comparisonBaselineCount = firstPositionFiles.count
                try await session.send(.mouse(.absoluteMove(x: expectedFrame.x(0.75), y: expectedFrame.y(0.5))))
                try await session.flushPendingInput()
                try await clickInputVisualTargetIfConfigured(session: session)
            }

            _ = await waitForFrameCount(
                renderer: renderer,
                count: comparisonBaselineCount + 2,
                timeout: .seconds(3)
            )
            let postInputFiles = await renderer.snapshotFiles()
            let comparisonImage = postInputFiles.dropFirst(comparisonBaselineCount).last ?? postInputFiles.last

            switch configuration.inputVisualProbeMode {
            case .disabled:
                break
            case .reversibleRelativeMotion:
                try? await session.send(.mouse(.relativeMove(dx: -96, dy: 0)))
                try? await session.flushPendingInput()
            case .absolutePointerSweep:
                try? await session.send(.mouse(.absoluteMove(x: 0.5, y: 0.5)))
                try? await session.flushPendingInput()
            }

            let inputPacketsAfter = await session.currentMetricsSnapshot().inputPacketsSent
            guard let comparisonImage else {
                return InputVisualProbeResult(
                    mode: configuration.inputVisualProbeMode,
                    attempted: true,
                    passed: false,
                    inputPacketsBefore: inputPacketsBefore,
                    inputPacketsAfter: inputPacketsAfter,
                    baselineImagePath: comparisonBaseline.path,
                    comparisonImagePath: nil,
                    meanRGBDelta: nil,
                    rmsRGBDelta: nil,
                    maxRGBDelta: nil,
                    changedPixels: nil,
                    changedPixelRatio: nil,
                    changedBounds: nil,
                    expectedRegions: [],
                    targetPresence: baselineTargetPresence,
                    warning: "\(warningPrefix): no post-input frame was captured"
                )
            }

            let delta = try ImageDeltaAnalyzer.measure(
                referenceFile: comparisonBaseline,
                comparisonFile: comparisonImage
            )
            let expectedRegions = try expectedInputVisualRegions(
                referenceFile: comparisonBaseline,
                comparisonFile: comparisonImage
            )
            let comparisonTargetPresence = try? ImageDeltaAnalyzer.detectInputVisualTarget(
                file: comparisonImage,
                expectedFrame: configuration.inputVisualExpectedFrame
            )
            let requiredTargetVisible = configuration.inputVisualTargetURL == nil
                || (baselineTargetPresence?.detected == true && comparisonTargetPresence?.detected == true)
            let visualChangeDetected = delta?.indicatesVisualChange(
                minChangedPixelRatio: configuration.inputVisualProbeMinChangedPixelRatio
            ) ?? false
            let packetsAdvanced = inputPacketsAfter > inputPacketsBefore
            let passed = packetsAdvanced && visualChangeDetected && requiredTargetVisible
            return InputVisualProbeResult(
                mode: configuration.inputVisualProbeMode,
                attempted: true,
                passed: passed,
                inputPacketsBefore: inputPacketsBefore,
                inputPacketsAfter: inputPacketsAfter,
                baselineImagePath: comparisonBaseline.path,
                comparisonImagePath: comparisonImage.path,
                meanRGBDelta: delta?.meanRGBDelta,
                rmsRGBDelta: delta?.rmsRGBDelta,
                maxRGBDelta: delta?.maxRGBDelta,
                changedPixels: delta?.changedPixels,
                changedPixelRatio: delta?.changedPixelRatio,
                changedBounds: delta?.changedBounds,
                expectedRegions: expectedRegions,
                targetPresence: comparisonTargetPresence ?? baselineTargetPresence,
                warning: passed ? nil : "\(warningPrefix): packetsAdvanced=\(packetsAdvanced) targetVisible=\(requiredTargetVisible)"
            )
        } catch {
            let inputPacketsAfter = await session.currentMetricsSnapshot().inputPacketsSent
            return InputVisualProbeResult(
                mode: configuration.inputVisualProbeMode,
                attempted: true,
                passed: false,
                inputPacketsBefore: inputPacketsBefore,
                inputPacketsAfter: inputPacketsAfter,
                baselineImagePath: baselineImage.path,
                comparisonImagePath: nil,
                meanRGBDelta: nil,
                rmsRGBDelta: nil,
                maxRGBDelta: nil,
                changedPixels: nil,
                changedPixelRatio: nil,
                changedBounds: nil,
                expectedRegions: [],
                targetPresence: baselineTargetPresence,
                warning: "\(warningPrefix): \((error as? MoonlightError)?.message ?? error.localizedDescription)"
            )
        }
    }

    private func waitForInputVisualTargetFrame(
        renderer: FrameCaptureRenderer,
        timeout: Duration
    ) async -> (file: URL, targetPresence: InputVisualTargetPresenceSummary?)? {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var latest: (file: URL, targetPresence: InputVisualTargetPresenceSummary?)?

        while clock.now < deadline {
            if let file = await renderer.snapshotFiles().last {
                let presence = try? ImageDeltaAnalyzer.detectInputVisualTarget(
                    file: file,
                    expectedFrame: configuration.inputVisualExpectedFrame
                )
                latest = (file: file, targetPresence: presence)
                if presence?.detected == true {
                    return latest
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return latest?.targetPresence?.detected == true ? latest : nil
            }
        }

        return latest?.targetPresence?.detected == true ? latest : nil
    }

    private func moveActiveWindowAcrossDisplays(session: MoonlightSession) async throws {
        let directions: [KeyCode] = [.rightArrow, .leftArrow, .rightArrow, .leftArrow]
        for direction in directions {
            try await sendWindowsShiftArrow(direction, session: session)
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    private func sendWindowsShiftArrow(_ arrow: KeyCode, session: MoonlightSession) async throws {
        let modifiers: KeyModifiers = [.command, .shift]
        try await sendKeyDown(.leftCommand, modifiers: [.command], session: session)
        try await sendKeyDown(.shift, modifiers: modifiers, session: session)
        try await sendKeyDown(arrow, modifiers: modifiers, session: session)
        try await sendKeyUp(arrow, modifiers: modifiers, session: session)
        try await sendKeyUp(.shift, modifiers: [.command], session: session)
        try await sendKeyUp(.leftCommand, session: session)
        try await session.flushPendingInput()
    }

    private func clickInputVisualTargetIfConfigured(session: MoonlightSession) async throws {
        guard configuration.inputVisualTargetURL != nil else {
            return
        }

        try await session.send(.mouse(.button(button: .left, state: .pressed)))
        try await session.send(.mouse(.button(button: .left, state: .released)))
        try await session.flushPendingInput()
    }

    private func expectedInputVisualRegions(
        referenceFile: URL,
        comparisonFile: URL
    ) throws -> [ImageDeltaRegionSummary] {
        guard configuration.inputVisualProbeMode == .absolutePointerSweep else {
            return []
        }

        let expectedFrame = configuration.inputVisualExpectedFrame
        return try ImageDeltaAnalyzer.measureRegions(
            referenceFile: referenceFile,
            comparisonFile: comparisonFile,
            requests: [
                ImageDeltaRegionRequest(name: "from25", centerXRatio: expectedFrame.x(0.25), centerYRatio: expectedFrame.y(0.5), halfExtent: 96),
                ImageDeltaRegionRequest(name: "to75", centerXRatio: expectedFrame.x(0.75), centerYRatio: expectedFrame.y(0.5), halfExtent: 96),
            ]
        )
    }

    private func waitForFrameCount(
        renderer: FrameCaptureRenderer,
        count: Int,
        timeout: Duration
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await renderer.snapshotFiles().count >= count {
                return true
            }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return await renderer.snapshotFiles().count >= count
            }
        }
        return await renderer.snapshotFiles().count >= count
    }

    private func waitForRequiredSignals(
        renderer: FrameCaptureRenderer,
        runtime: SessionRuntime
    ) async -> RuntimeObservationSnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now + configuration.timeout
        var snapshot = await runtime.snapshot()

        while clock.now < deadline {
            let files = await renderer.snapshotFiles()
            let hasRequiredFrames = files.count >= configuration.frameLimit
            snapshot = await runtime.snapshot()
            let hasRequiredAudio = !configuration.requireAudio || snapshot.audioPacketsObserved > 0

            if hasRequiredFrames && hasRequiredAudio {
                return snapshot
            }

            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return snapshot
            }
        }

        return await runtime.snapshot()
    }

    private func mergedMetrics(
        recorded: SessionMetricsSnapshot,
        current: SessionMetricsSnapshot,
        runtime: RuntimeObservationSnapshot
    ) -> SessionMetricsSnapshot {
        var merged = recorded
        merged.sessionOpenDurationMs = recorded.sessionOpenDurationMs ?? current.sessionOpenDurationMs
        merged.inputEventsSent = max(recorded.inputEventsSent, current.inputEventsSent)
        merged.inputPacketsSent = max(recorded.inputPacketsSent, current.inputPacketsSent)
        merged.rendererAttachments = max(recorded.rendererAttachments, current.rendererAttachments)
        merged.audioSinkAttachments = max(recorded.audioSinkAttachments, current.audioSinkAttachments)
        merged.establishedChannelCount = max(recorded.establishedChannelCount, current.establishedChannelCount)
        merged.controlMessagesObserved = max(recorded.controlMessagesObserved, current.controlMessagesObserved, runtime.controlMessagesObserved)
        merged.videoPacketsObserved = max(recorded.videoPacketsObserved, current.videoPacketsObserved, runtime.videoPacketsObserved)
        merged.audioPacketsObserved = max(recorded.audioPacketsObserved, current.audioPacketsObserved, runtime.audioPacketsObserved)
        merged.audioConcealmentPackets = max(recorded.audioConcealmentPackets, current.audioConcealmentPackets, runtime.audioConcealmentPackets)
        merged.missingVideoPackets = max(recorded.missingVideoPackets, current.missingVideoPackets, runtime.missingVideoPackets)
        merged.missingAudioPackets = max(recorded.missingAudioPackets, current.missingAudioPackets, runtime.missingAudioPackets)
        merged.reorderedVideoPackets = max(recorded.reorderedVideoPackets, current.reorderedVideoPackets, runtime.reorderedVideoPackets)
        merged.reorderedAudioPackets = max(recorded.reorderedAudioPackets, current.reorderedAudioPackets, runtime.reorderedAudioPackets)
        merged.videoDiscontinuityEvents = max(recorded.videoDiscontinuityEvents, current.videoDiscontinuityEvents, runtime.videoDiscontinuityEvents)
        merged.recoverableVideoDecodeFailures = max(recorded.recoverableVideoDecodeFailures, current.recoverableVideoDecodeFailures, runtime.recoverableVideoDecodeFailures)
        merged.reconnectAttempts = max(recorded.reconnectAttempts, current.reconnectAttempts, runtime.reconnectAttempts)
        merged.decodedVideoFrames = max(recorded.decodedVideoFrames, current.decodedVideoFrames)
        merged.renderedVideoFrames = max(recorded.renderedVideoFrames, current.renderedVideoFrames)
        merged.decodedAudioBuffers = max(recorded.decodedAudioBuffers, current.decodedAudioBuffers)
        merged.playedAudioBuffers = max(recorded.playedAudioBuffers, current.playedAudioBuffers)
        merged.averageVideoDecodeLatencyMs = current.averageVideoDecodeLatencyMs ?? recorded.averageVideoDecodeLatencyMs
        merged.maxVideoDecodeLatencyMs = current.maxVideoDecodeLatencyMs ?? recorded.maxVideoDecodeLatencyMs
        merged.averageHostProcessingLatencyMs = current.averageHostProcessingLatencyMs ?? recorded.averageHostProcessingLatencyMs
        merged.maxHostProcessingLatencyMs = current.maxHostProcessingLatencyMs ?? recorded.maxHostProcessingLatencyMs
        merged.averageAudioDecodeLatencyMs = current.averageAudioDecodeLatencyMs ?? recorded.averageAudioDecodeLatencyMs
        merged.maxAudioDecodeLatencyMs = current.maxAudioDecodeLatencyMs ?? recorded.maxAudioDecodeLatencyMs
        merged.averageInputQueueLatencyMs = current.averageInputQueueLatencyMs ?? recorded.averageInputQueueLatencyMs
        merged.maxInputQueueLatencyMs = current.maxInputQueueLatencyMs ?? recorded.maxInputQueueLatencyMs
        merged.averageInputTransportLatencyMs = current.averageInputTransportLatencyMs ?? recorded.averageInputTransportLatencyMs
        merged.maxInputTransportLatencyMs = current.maxInputTransportLatencyMs ?? recorded.maxInputTransportLatencyMs
        merged.audioUnderrunEvents = max(recorded.audioUnderrunEvents, current.audioUnderrunEvents)
        merged.unexpectedDisconnect = recorded.unexpectedDisconnect || current.unexpectedDisconnect || runtime.unexpectedDisconnect
        return merged
    }

    private func selectHost(from storedHosts: [MoonlightHost], client: MoonlightClient) async throws -> MoonlightHost {
        if let hostOverride = configuration.hostOverride {
            let exactMatches = storedHosts.filter {
                $0.endpoint.address == hostOverride.address && $0.endpoint.port == hostOverride.port
            }
            if let pairedExactMatch = exactMatches.first(where: \.pairingState.isPaired) {
                return pairedExactMatch
            }

            let pairedHosts = storedHosts.filter(\.pairingState.isPaired)
            if pairedHosts.count == 1 {
                return try await client.updateHostEndpoint(hostID: pairedHosts[0].id, endpoint: hostOverride)
            }

            if let exactMatch = exactMatches.first {
                return exactMatch
            }

            throw MoonlightError(
                .hostNotFound,
                message: "No stored host matches \(hostOverride.address):\(hostOverride.port), and override adoption requires exactly one paired stored host"
            )
        }

        if let pairedHost = storedHosts.first(where: \.pairingState.isPaired) {
            return pairedHost
        }

        throw MoonlightError(.hostNotFound, message: "No paired hosts found in saved storage")
    }

    private func selectAppID(from apps: [RemoteApp]) -> String {
        if let appIDOverride = configuration.appIDOverride,
           apps.contains(where: { $0.id == appIDOverride }) {
            return appIDOverride
        }
        if let desktop = apps.first(where: { $0.id.lowercased() == "desktop" || $0.name.lowercased() == "desktop" }) {
            return desktop.id
        }
        return apps.first?.id ?? "desktop"
    }
}

private extension String {
    func utf8ByteLimitedChunks(maxBytes: Int) -> [String] {
        guard maxBytes > 0 else { return [self] }

        var chunks: [String] = []
        var current = ""
        var currentBytes = 0
        for character in self {
            let characterBytes = character.utf8.count
            if currentBytes > 0, currentBytes + characterBytes > maxBytes {
                chunks.append(current)
                current = ""
                currentBytes = 0
            }
            current.append(character)
            currentBytes += characterBytes
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }
}
#else
import SwiftMoonlight

@main
struct CaptureCommand {
    static func main() {
        fputs("swift-moonlight-capture requires CoreImage/CoreVideo/ImageIO support\n", stderr)
        exit(EXIT_FAILURE)
    }
}
#endif
