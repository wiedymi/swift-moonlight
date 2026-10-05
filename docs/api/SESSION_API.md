# Session API

This document defines the runtime API once a stream session is open.

## Primary Types

```swift
public struct StreamConfiguration: Sendable {
    public var resolution: CGSize
    public var frameRate: Int
    public var bitrateKbps: Int
    public var dynamicRange: DynamicRangePreference
    public var videoCodecPreference: [VideoCodec]
    public var audioMode: AudioMode
    public var preferredDecodeMode: DecodeModePreference
    public var enableControlEncryption: Bool
    public var enableVideoEncryption: Bool
    public var enableAudioEncryption: Bool
    public var playAudioOnHost: Bool
    public var requestContinuousAudio: Bool
    public var attachedGamepadMask: Int
    public var persistGamepadsAfterDisconnect: Bool
}

public enum DecodeModePreference: Sendable {
    case hardwareFirst
    case hardwareOnly
    case softwareFallback
}

public actor MoonlightSession {
    public var events: AsyncStream<SessionEvent> { get }
    public var metrics: AsyncStream<SessionMetricsSnapshot> { get }

    public func attachVideoDecoder(_ decoder: any VideoDecoder) async throws
    public func attachRenderer(_ renderer: any FrameRenderer) async throws
    public func attachAudioDecoder(_ decoder: any AudioDecoder) async throws
    public func attachAudioSink(_ sink: any AudioSink) async throws
    public func attachInputSender(_ sender: any InputSending)
    public func attachControllerFeedbackSink(_ sink: (any ControllerFeedbackSink)?)
    public func configureVideo(format: VideoFormat) async throws
    public func configureAudio(format: AudioFormat) async throws
    public func receive(_ frame: EncodedVideoFrame) async throws
    public func receive(_ packet: EncodedAudioPacket) async throws
    public func send(_ event: InputEvent) async throws
    public func flushPendingInput() async throws
    public func stop() async
}

public actor SessionRuntime {
    public init(
        session: MoonlightSession,
        controlService: ControlChannelService? = nil,
        videoService: VideoIngestService? = nil,
        audioService: AudioIngestService? = nil,
        configuration: StreamRuntimeConfiguration = .init()
    )
    public func start() async
    public func stop() async
}
```

`SessionMetricsSnapshot` is `Codable` for CI artifacts and app-side diagnostics. Current fields include:
- session open duration
- input events sent
- input packets sent
- average input queue latency
- max input queue latency
- average input transport-send latency
- max input transport-send latency
- renderer attachments
- audio sink attachments
- established channel count
- control messages observed
- control round-trip time
- control round-trip time variance
- control packet-loss ratio
- control packet-loss variance ratio
- video packets observed
- audio packets observed
- audio concealment packets
- missing video packets
- missing audio packets
- reordered video packets
- reordered audio packets
- video discontinuity events
- video frame FEC status reports
- recoverable video decode failures
- reconnect attempts
- decoded video frames
- rendered video frames
- decoded audio buffers
- played audio buffers
- average video decode latency
- max video decode latency
- average and max time from completed video frame to pipeline start
- average and max time spent submitting a decoded frame to the renderer
- average host processing latency
- max host processing latency
- average audio decode latency
- max audio decode latency
- audio underrun events
- unexpected disconnect flag

The video queue time includes pipeline backpressure. Render submission time
includes a renderer's wait for a Metal drawable and command submission. It does
not measure when a frame becomes visible. The audio loop publishes metrics at
most every 100 ms during a stream and once more when its packet source ends.

Socket-backed runtime helpers are also available for negotiated UDP channels:

```swift
public struct PreparedSessionRuntime: Sendable {
    public let runtime: SessionRuntime
    public let sockets: ChannelSocketSet
    public func stop() async
}

public struct SessionRestartOptions: Sendable, Equatable {
    public var stopExistingRuntime: Bool
    public var cancelCurrentAppBeforeRelaunch: Bool
    public var runtimeConfiguration: StreamRuntimeConfiguration
}

public struct RestartedSession: Sendable {
    public var session: MoonlightSession
    public var preparedRuntime: PreparedSessionRuntime
}

public struct StreamRuntimeConfiguration: Sendable, Equatable {
    public var controlEncryption: ControlEncryptionContext?
    public var stopOnControlTermination: Bool
    public var maxReconnectAttempts: Int
    public var reconnectBackoff: Duration
    public var inputSenderConfiguration: InputSenderConfiguration
    public var videoPipelineSubmissionMode: VideoPipelineSubmissionMode
    public var videoPacketTraceLimit: Int
}

public struct ChannelSocketFactory: Sendable {
    public func makeSockets(
        for host: MoonlightHost,
        negotiatedSession: NegotiatedSession
    ) throws -> ChannelSocketSet
}

public struct SessionRuntimeFactory: Sendable {
    public init(
        socketFactory: ChannelSocketFactory = .init(),
        logger: any MoonlightLogger
    )

    public func makeRuntime(
        host: MoonlightHost,
        session: MoonlightSession,
        configuration: StreamRuntimeConfiguration = .init()
    ) async throws -> PreparedSessionRuntime
}
```

Negotiated sessions now also carry transport-facing encryption metadata:

```swift
public struct RemoteInputSecrets: Sendable {
    public var key: Data
    public var keyID: UInt32
}

public struct NegotiatedSession: Sendable {
    public var remoteInputSecrets: RemoteInputSecrets?
    public var encryptionFeatures: SessionEncryptionFeatures
}
```

## Usage

```swift
let session = try await client.openSession(
    hostID: host.id,
    appID: app.id,
    configuration: .default1080p60
)

let target = try MetalLayerTarget(
    device: device,
    layer: metalLayer,
    presentationConfiguration: MetalPresentationConfiguration(contentMode: .stretch)
)
let renderer = try MetalRenderer(device: device, target: target)
let inputSender = InputSender(
    context: InputEncodingContext(hostKind: .sunshine),
    transport: inputTransport
)

try await session.attachVideoDecoder(VideoToolboxDecoder())
try await session.attachRenderer(renderer)
try await session.attachAudioDecoder(OpusDecoder())
try await session.attachAudioSink(SystemAudioSink())
await session.attachInputSender(inputSender)
try await session.send(.keyboard(.keyDown(.space)))
try await session.flushPendingInput()

let runtime = SessionRuntime(
    session: session,
    controlService: controlService,
    videoService: videoService,
    audioService: audioService
)
await runtime.start()

let prepared = try await client.prepareRuntime(for: session, hostID: host.id)
await prepared.runtime.start()
await prepared.stop()

let restarted = try await client.restartSession(
    hostID: host.id,
    appID: app.id,
    configuration: resizedConfiguration,
    previousRuntime: prepared
)
try await AppleMediaComponents.attachRecommendedPlaybackComponents(
    to: restarted.session,
    device: device,
    layer: metalLayer,
    presentationConfiguration: MetalPresentationConfiguration(contentMode: .stretch)
)
await restarted.preparedRuntime.runtime.start()
```

Apple playback convenience:

```swift
try await AppleMediaComponents.attachRecommendedPlaybackComponents(
    to: session,
    device: device,
    layer: metalLayer,
    presentationConfiguration: MetalPresentationConfiguration(contentMode: .stretch)
)
```

Current runtime behavior:
- `MoonlightClient.openSession(...)` validates `StreamConfiguration` before host lookup or launch. Invalid resolution, frame rate, bitrate, or empty codec preferences fail with `MoonlightError.Code.capabilityMismatch`.
- after host refresh, `MoonlightClient.openSession(...)` validates requested codec, HDR, decode mode, and above-4K requirements against `HostCapabilities` before sending launch side effects
- `StreamConfiguration.playAudioOnHost` maps to Moonlight's `localAudioPlayMode` launch setting for keeping host-side audio playback enabled while streaming
- `StreamConfiguration.requestContinuousAudio` maps to the Sunshine/Apollo launch option that asks the host to keep audio packets flowing even when normal desktop audio would otherwise be quiet
- `StreamConfiguration.attachedGamepadMask` maps to Moonlight's `remoteControllersBitmap` and `gcmap` launch settings so hosts can prepare virtual gamepads before the first controller packet arrives
- `StreamConfiguration.persistGamepadsAfterDisconnect` maps to Moonlight's `gcpersist` launch setting
- `SessionRuntimeFactory` auto-configures control encryption when negotiated control-v2 support is enabled
- `SessionRuntimeFactory` auto-attaches video/audio decryptors when the negotiated session enables encrypted media and carries remote-input key material
- `SessionRuntimeFactory` attaches the input sender with `StreamRuntimeConfiguration.inputSenderConfiguration`, so apps can keep the default Moonlight-style 1 ms coalesced mouse delivery or opt into immediate mouse delivery for diagnostics and sparse pointer sources
- `StreamRuntimeConfiguration.videoPipelineSubmissionMode` defaults to bounded ordered asynchronous submission, so socket receive and depacketization can keep draining RTP bursts while decode/render for earlier frames is still in flight
- `StreamRuntimeConfiguration.videoPacketTraceLimit` enables a bounded in-memory ring of parsed video packet headers for smoke/debug tools; it defaults to `0` and should stay disabled in normal app runtime paths
- `MoonlightSession.flushPendingInput()` flushes pending coalesced input through attached senders that support `InputFlushing`; call it before focus/capture transitions when the newest pointer position must be delivered before a later input event or teardown
- `MoonlightSession.stop()` performs a best-effort pending-input flush before transitioning to stopped; explicit `flushPendingInput()` is still preferred when app code needs to observe transport failures
- UDP readiness waits enter an explicit actor method before storing their continuation. Release socket checks cover repeated waits, cancellation, and close.
- `PreparedSessionRuntime.stop()` now tears down both the runtime tasks and the owned channel sockets
- `MoonlightClient.restartSession(...)` centralizes the stop/cancel/relaunch sequence used for app-driven restarts. It validates the replacement configuration before stopping the old runtime, optionally sends host cancel, opens a replacement session, and prepares but does not start its runtime.
- `SessionRuntime` now pushes observed control/video/audio counters back into `session.metrics`, so app code and headless tests can use the session metric stream as the primary runtime-observation surface
- Video runtime metric publication is throttled to avoid doing control RTT refresh and media-pipeline snapshot work after every frame on the UDP receive loop; `SessionRuntime.snapshot()` still queries current counters on demand
- `SessionRuntime` now pushes ENet control RTT/loss telemetry into `session.metrics` when the attached control transport implements `ControlTransportMetricsReporting`
- `SessionRuntime` now also pushes media-pipeline latency and underrun metrics into `session.metrics`
- `SessionRuntime` now also pushes transport reorder/discontinuity counters into `session.metrics`
- `SessionRuntime` now also pushes missing-packet counters into `session.metrics`
- `SessionRuntime` now supports bounded retry after transient runtime errors through `StreamRuntimeConfiguration.maxReconnectAttempts` and `StreamRuntimeConfiguration.reconnectBackoff`
- `MoonlightClient.openSession(...)` now attaches the configured `MetricsSink` to the session metric stream
- `MoonlightSession.send(_:)`, `flushPendingInput()`, and `stop()` mirror input sender packet counts plus local queue/send latency metrics into `session.metrics` when the attached sender supports `InputMetricsReporting`
- direct `MoonlightSession.receive(...)` calls now also mirror media-pipeline decode/render/playback metrics into `session.metrics`, so headless non-runtime usage sees the same counters
- `SessionRuntime` now emits a session warning when the video ingest path reports a discontinuity, so headless callers can react before looking at metrics
- when a control channel is attached, `SessionRuntime` now also requests a new keyframe on video discontinuity using the current Sunshine/Apollo IDR control packet
- recoverable VideoToolbox bad-data decode failures are counted in `recoverableVideoDecodeFailures`, produce a warning, and request a new keyframe instead of failing the session immediately
- when a FEC-described video frame is unrecoverable, `SessionRuntime` sends a best-effort frame FEC status report and increments `session.metrics.videoFrameFECStatusReports`

Current missing-packet semantics:
- `missingVideoPackets` counts gaps from the next expected RTP sequence number when the video depacketizer declares a discontinuity
- `missingAudioPackets` currently tracks concealment-triggering missing audio packets in the bounded audio reorder path

Current reconnect semantics:
- reconnect is currently an in-runtime retry loop for transient `ControlChannelService`, `VideoIngestService`, and `AudioIngestService` failures
- it does not renegotiate launch, RTSP, or channels
- every retry increments `session.metrics.reconnectAttempts`

## Event Model

```swift
public enum SessionEvent: Sendable {
    case stateChanged(SessionState)
    case videoFormatChanged(VideoFormat)
    case audioFormatChanged(AudioFormat)
    case hdrModeChanged(HDRModeUpdate)
    case controllerFeedback(ControllerFeedback)
    case warning(MoonlightWarning)
    case failed(MoonlightError)
}
```

HDR mode events report host-side HDR activation separately from the requested
stream configuration. Apps should treat `dynamicRange == .hdr` as a request and
`hdrModeChanged(enabled:)` plus decoded frame metadata as evidence of what the
host actually delivered.

Controller feedback events carry the host-requested effect instead of only a
capability bit. The legacy `supportsRumble` boolean remains as a compatibility
shortcut for rumble and trigger-rumble effects.

```swift
public enum ControllerFeedbackEffect: Sendable, Equatable {
    case capabilities(supportsRumble: Bool)
    case rumble(lowFrequencyMotor: UInt16, highFrequencyMotor: UInt16)
    case triggerRumble(leftTriggerMotor: UInt16, rightTriggerMotor: UInt16)
    case motionReport(motionType: UInt8, reportRateHz: UInt16)
    case led(red: UInt8, green: UInt8, blue: UInt8)
    case adaptiveTriggers(
        eventFlags: UInt8,
        leftTriggerType: UInt8,
        rightTriggerType: UInt8,
        leftPayload: [UInt8],
        rightPayload: [UInt8]
    )
}

public protocol ControllerFeedbackSink: Sendable {
    func apply(_ feedback: ControllerFeedback) async throws
}
```

## DX Constraints

- attachable renderer and audio sink must be replaceable at runtime
- decoders and sinks must be attachable independently for headless and production use
- controller feedback sinks must be attachable independently from event-stream observation
- runtime packet pumping must stay separate from app-facing session use
- sessions must remain usable in headless mode
- event stream must be the primary observation channel for apps and tests
- metric stream must expose runtime observation counts without requiring direct access to `SessionRuntime.snapshot()`
