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
