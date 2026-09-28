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

struct CaptureConfiguration: Sendable {
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

enum CaptureInputVisualProbeMode: String, Sendable, Equatable, Codable, CustomStringConvertible {
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

struct InputVisualExpectedFrame: Sendable, Equatable, Codable {
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

#endif
