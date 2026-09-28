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

struct HeadlessCaptureRunner {
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
#endif
