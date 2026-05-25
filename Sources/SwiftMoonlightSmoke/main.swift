import Foundation
import SwiftMoonlight
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main
struct SmokeCommand {
    static func main() async {
        do {
            let storageDirectory = try resolveStorageDirectory()
            let harness = try IntegrationHarness.production(storageDirectory: storageDirectory)
            let report = try await harness.runSmokeTest()
            print(render(report))
            try writeJSONReportIfRequested(report)
            if !report.passed {
                exit(EXIT_FAILURE)
            }
        } catch let error as MoonlightError {
            fputs("swift-moonlight-smoke failed: \(error.message)\n", stderr)
            exit(EXIT_FAILURE)
        } catch {
            fputs("swift-moonlight-smoke failed: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func resolveStorageDirectory() throws -> URL {
        if let rawValue = ProcessInfo.processInfo.environment["SWIFT_MOONLIGHT_TEST_STORAGE_DIR"],
           !rawValue.isEmpty {
            let url = URL(fileURLWithPath: rawValue, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        let defaultURL = FileManager.default.temporaryDirectory
            .appending(path: "swift-moonlight-smoke", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: defaultURL, withIntermediateDirectories: true)
        return defaultURL
    }

    private static func render(_ report: SmokeTestReport) -> String {
        let failures = report.failures()
        let failureText = failures.isEmpty ? "[]" : failures.joined(separator: "; ")
        return """
        paired=\(report.paired)
        appsFetched=\(report.appsFetched)
        preLaunchCancelAttempted=\(report.preLaunchCancelAttempted)
        launchAccepted=\(report.launchAccepted)
        controlConnected=\(report.controlConnected)
        inputConnected=\(report.inputConnected)
        controlRoundTripTimeMs=\(optionalString(report.controlRoundTripTimeMs))
        controlRoundTripTimeVarianceMs=\(optionalString(report.controlRoundTripTimeVarianceMs))
        controlPacketLossRatio=\(stringValue(report.controlPacketLossRatio))
        controlPacketLossVarianceRatio=\(stringValue(report.controlPacketLossVarianceRatio))
        videoPacketsObserved=\(report.videoPacketsObserved)
        audioPacketsObserved=\(report.audioPacketsObserved)
        missingVideoPackets=\(report.missingVideoPackets)
        reorderedVideoPackets=\(report.reorderedVideoPackets)
        videoDiscontinuityEvents=\(report.videoDiscontinuityEvents)
        videoFrameFECStatusReports=\(report.videoFrameFECStatusReports)
        decodedVideoFrames=\(report.decodedVideoFrames)
        renderedVideoFrames=\(report.renderedVideoFrames)
        inputPacketsSent=\(report.inputPacketsSent)
        averageInputQueueLatencyMs=\(stringValue(report.averageInputQueueLatencyMs))
        maxInputQueueLatencyMs=\(stringValue(report.maxInputQueueLatencyMs))
        averageInputTransportLatencyMs=\(stringValue(report.averageInputTransportLatencyMs))
        maxInputTransportLatencyMs=\(stringValue(report.maxInputTransportLatencyMs))
        inputProbeSucceeded=\(report.inputProbeSucceeded)
        inputProbeMode=\(report.inputProbeMode.rawValue)
        inputProbeRepeatCount=\(report.inputProbeRepeatCount)
        maxInputLatencyMs=\(stringValue(report.maxInputLatencyMs))
        maxMissingVideoPackets=\(optionalString(report.maxMissingVideoPackets))
        maxVideoDiscontinuities=\(optionalString(report.maxVideoDiscontinuities))
        videoPacketTrace=\(videoPacketTraceSummary(report.videoPacketTrace))
        audioExpected=\(report.audioExpected)
        unexpectedDisconnect=\(report.unexpectedDisconnect)
        restartAttempted=\(report.restartAttempted)
        restartLaunchAccepted=\(report.restartLaunchAccepted)
        restartControlConnected=\(report.restartControlConnected)
        restartInputConnected=\(report.restartInputConnected)
        restartVideoPacketsObserved=\(report.restartVideoPacketsObserved)
        restartAudioPacketsObserved=\(report.restartAudioPacketsObserved)
        restartDecodedVideoFrames=\(report.restartDecodedVideoFrames)
        restartRenderedVideoFrames=\(report.restartRenderedVideoFrames)
        restartUnexpectedDisconnect=\(report.restartUnexpectedDisconnect)
        restartCountRequested=\(report.restartCountRequested)
        restartObservations=\(restartObservationSummary(report.restartObservations))
        passed=\(report.passed)
        failures=\(failureText)
        """
    }

    private static func stringValue(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(value)
    }

    private static func optionalString(_ value: Int?) -> String {
        guard let value else { return "" }
        return String(value)
    }

    private static func writeJSONReportIfRequested(_ report: SmokeTestReport) throws {
        guard let rawPath = ProcessInfo.processInfo.environment["SWIFT_MOONLIGHT_TEST_REPORT_JSON"],
              !rawPath.isEmpty
        else {
            return
        }

        let fileURL = URL(fileURLWithPath: rawPath)
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(SmokeJSONReport(report: report))
        try data.write(to: fileURL, options: .atomic)
    }

    private static func restartObservationSummary(_ observations: [SmokeRestartObservation]) -> String {
        guard !observations.isEmpty else {
            return "[]"
        }
        return observations.map {
            "#\($0.index):launch=\($0.launchAccepted),control=\($0.controlConnected),input=\($0.inputConnected)," +
            "rtt=\(optionalString($0.controlRoundTripTimeMs)),video=\($0.videoPacketsObserved),audio=\($0.audioPacketsObserved)," +
            "fec=\($0.videoFrameFECStatusReports),disconnect=\($0.unexpectedDisconnect)"
        }.joined(separator: " | ")
    }

    private static func videoPacketTraceSummary(_ trace: [VideoPacketTraceEntry]) -> String {
        guard !trace.isEmpty else {
            return "[]"
        }
        return trace.map {
            "#\($0.observedPacketIndex):seq=\($0.sequenceNumber),frame=\($0.frameIndex)," +
            "stream=\($0.streamPacketIndex),flags=\(String(format: "%02X", $0.flags))," +
            "shard=\($0.fecShardIndex)/\($0.dataShardCount),fec=\($0.fecPercentage)," +
            "block=\($0.fecBlockIndex)/\($0.fecLastBlockIndex),synthetic=\($0.usedSyntheticSequenceNumber)"
        }.joined(separator: " | ")
    }
}

private struct SmokeJSONReport: Codable {
    let schemaVersion: Int
    let kind: String
    let generatedAt: String
    let passed: Bool
    let failures: [String]
    let report: SmokeTestReport

    init(report: SmokeTestReport) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.schemaVersion = 1
        self.kind = "swift-moonlight-smoke"
        self.generatedAt = formatter.string(from: Date())
        self.passed = report.passed
        self.failures = report.failures()
        self.report = report
    }
}
