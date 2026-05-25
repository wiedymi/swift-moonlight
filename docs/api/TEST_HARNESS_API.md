# Test Harness API

This document defines the headless integration surface.

## Goal

Make interoperability tests look like product usage, not packet scripts.

## Primary Types

```swift
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

    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> IntegrationHarnessConfiguration
}

public enum InputProbeMode: String, Sendable, Equatable, Codable {
    case disabled
    case noop
    case reversibleRelativeMotion
    case absolutePointerSweep
}

public actor IntegrationHarness {
    public init(
        client: MoonlightClient,
        configuration: IntegrationHarnessConfiguration
    )

    public func runSmokeTest() async throws -> SmokeTestReport

    public static func production(
        storageDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logger: any MoonlightLogger = DefaultLogger(),
        metricsSink: any MetricsSink = NoopMetricsSink(),
        enableDiscovery: Bool = true,
        httpClient: (any HTTPClient)? = nil
    ) throws -> IntegrationHarness
}
```

```swift
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
}

public struct VideoPacketTraceEntry: Sendable, Equatable, Codable {
    public var observedPacketIndex: Int
    public var usedDecryptor: Bool
    public var usedSyntheticSequenceNumber: Bool
    public var encryptedByteCount: Int
    public var rawByteCount: Int
    public var sequenceNumber: UInt16
    public var frameIndex: UInt32
    public var streamPacketIndex: UInt32
    public var flags: UInt8
    public var fecShardIndex: UInt16
    public var dataShardCount: UInt16
    public var fecPercentage: UInt8
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

    public var passed: Bool { get }
    public func failures(requireVideoPackets: Bool = true) -> [String]
}
```

## Usage

```swift
let report = try await IntegrationHarness(
    client: client,
    configuration: .init(
        endpoint: .init(address: host, port: 47989),
        pinProvider: { "1234" },
        appID: "desktop",
        streamConfiguration: .default1080p60,
        observationWindow: .seconds(10)
    )
).runSmokeTest()

XCTAssertTrue(report.launchAccepted)
XCTAssertFalse(report.unexpectedDisconnect)
XCTAssertTrue(report.failures(requireVideoPackets: false).isEmpty)
```

Or build it directly from the documented environment variables:

```swift
let harness = try IntegrationHarness.production(
    storageDirectory: appSupportDirectory
)

let report = try await harness.runSmokeTest()
print(report.failures())
```

Or run the package executable:

```bash
swift run swift-moonlight-smoke
```

## DX Constraints

- the harness should reuse the public client API
- the harness should use `NullRenderer` and `NullAudioSink` by default
- the harness report must be structured enough for CI assertions
- smoke input probing must avoid clicks, text, and destructive shortcuts so it can run safely against a real desktop session
- input latency thresholds are local sender/transport checks only; they do not prove exact host cursor position

## Current Implementation Notes

- `IntegrationHarness` now exists in Sources and runs through `addHost`, `refreshHost`, `pair`, `fetchApps`, `openSession`, and `prepareRuntime`
- the current default harness attaches `DiscardingVideoDecoder`, `SilenceAudioDecoder`, `NullRenderer`, and `NullAudioSink`
- packet observation is currently sourced from runtime ingest counters
- `videoPacketsObserved` and `audioPacketsObserved` are transport-observation counts, not decoded-frame counts
- when the input channel is connected, the harness sends the configured input probe and fails the report if that probe cannot complete, unless the probe is explicitly disabled
- smoke reports include input sender packet counts plus local queue and transport-send latency metrics when an input sender is attached
- the default input probe is `noop`, which sends a no-op relative mouse move plus a zero scroll packet
- `reversibleRelativeMotion` sends `+1` and `-1` relative mouse moves with an explicit flush after each event, providing nonzero input transport evidence without clicking or typing
- `absolutePointerSweep` sends absolute pointer moves at 25%, 75%, and 50% of the active stream surface, providing direct-pointer transport evidence without clicks or text input
- `SWIFT_MOONLIGHT_TEST_INPUT_PROBE_REPEAT_COUNT=50` repeats the safe input probe for sender-side input soak checks
- `SWIFT_MOONLIGHT_TEST_RESOLUTION=1280x720`, `SWIFT_MOONLIGHT_TEST_FPS=30`, and `SWIFT_MOONLIGHT_TEST_BITRATE_KBPS=8000` override the primary smoke stream settings for load-sensitive diagnostics
- `SWIFT_MOONLIGHT_TEST_DYNAMIC_RANGE=sdr|hdr`, `SWIFT_MOONLIGHT_TEST_CODEC=h264`, and `SWIFT_MOONLIGHT_TEST_CODECS=hevc,h264` override the requested dynamic range and codec preference for the primary smoke launch
- `SWIFT_MOONLIGHT_TEST_MAX_INPUT_LATENCY_MS=20` fails the report if max local input queue latency or max transport-send latency exceeds the threshold
- `SWIFT_MOONLIGHT_TEST_MAX_MISSING_VIDEO_PACKETS=0` fails the report if a primary or restart observation reports more missing video packets than the configured threshold
- `SWIFT_MOONLIGHT_TEST_MAX_VIDEO_DISCONTINUITIES=0` fails the report if a primary or restart observation reports more video discontinuities than the configured threshold
- `SWIFT_MOONLIGHT_TEST_VIDEO_PACKET_TRACE_LIMIT=32` records the last 32 parsed video packet headers in the smoke report for live gap diagnostics
- `SWIFT_MOONLIGHT_TEST_CANCEL_BEFORE_LAUNCH=1` cancels the currently running host app before opening the primary smoke session, which helps repeated saved-pairing runs recover from stale host sessions
- `IntegrationHarnessConfiguration.fromEnvironment(...)` currently reads:
  - `SWIFT_MOONLIGHT_TEST_HOST`
  - `SWIFT_MOONLIGHT_TEST_PIN`
  - `SWIFT_MOONLIGHT_TEST_PASSPHRASE`
  - `SWIFT_MOONLIGHT_TEST_APP_ID`
  - `SWIFT_MOONLIGHT_TEST_RESOLUTION`
  - `SWIFT_MOONLIGHT_TEST_FPS`
  - `SWIFT_MOONLIGHT_TEST_BITRATE_KBPS`
  - `SWIFT_MOONLIGHT_TEST_DYNAMIC_RANGE`
  - `SWIFT_MOONLIGHT_TEST_CODEC`
  - `SWIFT_MOONLIGHT_TEST_CODECS`
  - `SWIFT_MOONLIGHT_TEST_CONTINUOUS_AUDIO`
  - `SWIFT_MOONLIGHT_TEST_REQUIRE_AUDIO`
  - `SWIFT_MOONLIGHT_TEST_INPUT_PROBE`
  - `SWIFT_MOONLIGHT_TEST_INPUT_PROBE_REPEAT_COUNT`
  - `SWIFT_MOONLIGHT_TEST_MAX_INPUT_LATENCY_MS`
  - `SWIFT_MOONLIGHT_TEST_MAX_MISSING_VIDEO_PACKETS`
  - `SWIFT_MOONLIGHT_TEST_MAX_VIDEO_DISCONTINUITIES`
  - `SWIFT_MOONLIGHT_TEST_VIDEO_PACKET_TRACE_LIMIT`
  - `SWIFT_MOONLIGHT_TEST_CANCEL_BEFORE_LAUNCH`
  - `SWIFT_MOONLIGHT_TEST_RESTART_RESOLUTION`
  - `SWIFT_MOONLIGHT_TEST_RESTART_COUNT`
  - `SWIFT_MOONLIGHT_TEST_OBSERVATION_SECONDS`
  - `SWIFT_MOONLIGHT_TEST_REPORT_JSON`
- `swift-moonlight-smoke` uses `SWIFT_MOONLIGHT_TEST_STORAGE_DIR` when provided, otherwise it creates a temporary storage directory
- with persisted storage, `swift-moonlight-smoke` prefers a paired exact endpoint match; when the configured endpoint matches only an unpaired duplicate and exactly one paired host exists, it updates the paired host endpoint instead of pairing a duplicate row
- `SWIFT_MOONLIGHT_TEST_APP_ID=desktop` can match either a literal app ID or an app named `Desktop`, so Apollo numeric Desktop IDs are selected correctly
- `SWIFT_MOONLIGHT_TEST_OBSERVATION_SECONDS=2.5` overrides the per-session observation window for quick local checks or longer soak runs
- `SWIFT_MOONLIGHT_TEST_RESTART_RESOLUTION=1600x900` runs a second session through `MoonlightClient.restartSession(...)` and adds restart channel/packet counters to `SmokeTestReport`
- `SWIFT_MOONLIGHT_TEST_RESTART_COUNT=3` repeats the restart path and adds one `SmokeRestartObservation` per attempt for resize/relaunch soak assertions
- `SWIFT_MOONLIGHT_TEST_REPORT_JSON=/tmp/smoke.json` makes `swift-moonlight-smoke` write a pretty-printed JSON artifact containing the Codable report plus derived `passed` and `failures` fields
- when `SWIFT_MOONLIGHT_TEST_PASSPHRASE` is present, the harness uses `PairingAuth.otp(pin:passphrase:)`
- `SmokeTestReport.passed` encodes the default smoke requirements:
  - paired
  - app list fetched
  - launch accepted
  - control connected
  - input connected
  - input probe completed when input is connected and probing is not disabled
  - video packets observed
  - video missing-packet and discontinuity counters do not exceed configured thresholds, when thresholds are set
  - audio packets observed when audio was negotiated
  - no unexpected disconnect
  - when restart is requested, every requested restart launch accepted, channels connected, video packets observed, and no restart disconnect
