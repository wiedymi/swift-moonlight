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

struct CaptureReport: Sendable {
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

struct ImageDeltaBounds: Sendable, Codable, CustomStringConvertible {
    let minX: Int
    let minY: Int
    let maxX: Int
    let maxY: Int

    var description: String {
        "\(minX),\(minY)-\(maxX),\(maxY)"
    }
}

struct ImageDeltaRegionRequest: Sendable {
    let name: String
    let centerXRatio: Double
    let centerYRatio: Double
    let halfExtent: Int
}

struct ImageDeltaRegionSummary: Sendable, Codable, CustomStringConvertible {
    let name: String
    let bounds: ImageDeltaBounds
    let changedPixels: Int
    let totalPixels: Int
    let changedPixelRatio: Double

    var description: String {
        "\(name):\(bounds.description):\(String(format: "%.5f", changedPixelRatio))"
    }
}

struct InputVisualTargetPresenceSummary: Sendable, Codable, CustomStringConvertible {
    let detected: Bool
    let sentinelRatios: [Double]

    var description: String {
        let ratios = sentinelRatios.map { String(format: "%.3f", $0) }.joined(separator: ",")
        return "detected=\(detected) sentinel=[\(ratios)]"
    }
}

struct ImageDeltaSummary: Sendable, Codable {
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

struct HDRModeCaptureState: Sendable, Codable {
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

struct InputVisualProbeResult: Sendable, Codable {
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

struct CaptureJSONReport: Codable {
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

struct HostPayload: Codable {
    let address: String
    let port: Int
    let securePort: Int?

    init(endpoint: HostEndpoint) {
        self.address = endpoint.address
        self.port = endpoint.port
        self.securePort = endpoint.securePort
    }
}

struct CapturedFramePlaneMetadata: Codable, Sendable {
    let index: Int
    let width: Int
    let height: Int
    let bytesPerRow: Int
}

struct CapturedFrameMetadata: Codable, Sendable {
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

#endif
