# Video and Audio API

This document defines the decode, render, and playback boundaries.

## Video Pipeline

Stages:
- packet ingestion
- depacketization
- access-unit reconstruction
- decode submission
- decoded frame delivery
- render submission

## Video Types

```swift
public struct EncodedVideoFrame: Sendable {
    public var timestamp: UInt64
    public var isKeyFrame: Bool
    public var codec: VideoCodec
    public var parameterSets: [Data]
    public var payload: Data
}

public protocol VideoDecoder: Sendable {
    func configure(format: VideoFormat) async throws
    func decode(_ frame: EncodedVideoFrame) async throws -> [DecodedVideoFrame]
    func flush() async throws -> [DecodedVideoFrame]
}

public protocol FrameRenderer: Sendable {
    func prepare(format: VideoFormat) async throws
    func render(_ frame: DecodedVideoFrame) async
    func teardown() async
}
```

Production implementations:
- `VideoToolboxDecoder`
- `FallbackVideoDecoder`
- `MetalRenderer`
- `MetalLayerTarget`
- `AppleMediaComponents`

Decoder selection:
- `VideoToolboxDecoder` is the hardware-first Apple decoder path for H.264 and HEVC.
- AV1 is rejected explicitly at `VideoToolboxDecoder.configure(format:)` until the AV1 format-description and sample conversion path is implemented.
- `FallbackVideoDecoder` can promote to its fallback decoder after either primary configuration failure or primary decode failure, so app-level code can provide a software decoder without special-casing the hardware path.
- `AppleMediaComponents.makeVideoDecoder(preferredDecodeMode:softwareFallback:)` maps `DecodeModePreference` into concrete decoder composition. `.softwareFallback` fails early when no software decoder is supplied instead of silently behaving like hardware-only decode.

Test implementations:
- `RecordingVideoDecoder`
- `NullRenderer`

Rules:
- decoder does not know about `MTKView`
- renderer does not know about packet structure
- `DecodedVideoFrame` is currently a concurrency-safe value type carrying timestamp, dimensions, and optional bytes
- Apple-specific frame backing should remain behind decoder/renderer boundaries rather than leaking non-`Sendable` objects into session core
- hardware-first selection should be implemented as decoder composition, not ad hoc app logic

Apple Metal presentation:
- `MetalPresentationConfiguration(contentMode:dynamicRangeMode:edrCapabilities:)` controls how decoded frames are mapped into the `CAMetalLayer`
- `.stretch` is the default and fills the whole layer; use it when input is normalized against the whole surface or the stream is relaunched to match the local surface size
- `.aspectFit` preserves frame aspect with letterboxing or pillarboxing
- `.aspectFill` preserves frame aspect while cropping overflow
- `.standardDynamicRange` is the default dynamic-range mode and presents through an SDR `bgra8Unorm` layer with HDR frames tone-mapped by the shader
- `.extendedDynamicRange` opts into an EDR-capable `rgba16Float` layer and extended-linear shader output; apps should only enable it after checking the display and validating host color metadata
- `.automatic` stays SDR unless the prepared `VideoFormat` is HDR and `edrCapabilities.supportsExtendedDynamicRange` is true
- `MetalPresentationEDRCapabilities(screen:)` can be built from `NSScreen` or `UIScreen` on the main actor so app code does not need to duplicate Apple EDR headroom checks
- `MetalPresentationGeometry` exposes the matching `contentRect`, normalized `sourceRect`, and `normalizedFramePoint(forDrawablePoint:)` mapping for absolute pointer input
- absolute pointer mapping must use the same presentation geometry chosen by the app, otherwise host cursor coordinates can drift from the pixels shown to the user

## Audio Pipeline

Stages:
- packet ingestion
- depacketization
- decode
- render sink submission

```swift
public struct PCMBuffer: Sendable {
    public var sampleRate: Int
    public var channelCount: Int
    public var frameCount: Int
    public var bytesPerFrame: Int
    public var data: Data
}

public protocol AudioDecoder: Sendable {
    func configure(format: AudioFormat) async throws
    func decode(_ packet: EncodedAudioPacket) async throws -> PCMBuffer
}

public protocol AudioSink: Sendable {
    func prepare(format: AudioFormat) async throws
    func play(_ buffer: PCMBuffer) async
    func teardown() async
}
```

Production implementations:
- `OpusDecoder`
- `SystemAudioSink`

Test implementations:
- `RecordingAudioDecoder`
- `NullAudioSink`

## Pipeline Actor

The current runtime composes decode and sink stages through `MediaPipeline`:

```swift
public actor MediaPipeline {
    public func attachVideoDecoder(_ decoder: any VideoDecoder) async throws
    public func attachRenderer(_ renderer: any FrameRenderer) async throws
    public func attachAudioDecoder(_ decoder: any AudioDecoder) async throws
    public func attachAudioSink(_ sink: any AudioSink) async throws
    public func configureVideo(format: VideoFormat) async throws
    public func configureAudio(format: AudioFormat) async throws
    public func ingestVideo(_ frame: EncodedVideoFrame) async throws
    public func flushVideo() async throws
    public func ingestAudio(_ packet: EncodedAudioPacket) async throws
}
```

## Ingest Services

The current runtime also exposes transport-facing ingest actors:

```swift
public actor ConnectedUDPSocket {
    public init(remoteHost: String, remotePort: UInt16, bindHost: String = "0.0.0.0", localPort: UInt16 = 0) throws
    public func localPort() throws -> UInt16
    public func send(_ packet: Data) throws
    public func receivePacket() async throws -> Data?
    public func close()
}

public struct ChannelSocketFactory: Sendable {
    public func makeSockets(for host: MoonlightHost, negotiatedSession: NegotiatedSession) throws -> ChannelSocketSet
}

public actor VideoIngestService {
    public func receiveNextFrame() async throws -> EncodedVideoFrame?
}

public actor AudioIngestService {
    public func receiveNextPacket() async throws -> EncodedAudioPacket?
}
```

These sit between raw media packet sources and `MediaPipeline`.

Current implementation note:
- `ConnectedUDPSocket` and `ChannelSocketFactory` provide the current loopback-tested runtime path from negotiated channels to control, input, video, and audio sockets
- `SystemAudioSink` is now implemented on Apple platforms via `AVAudioEngine` and `AVAudioPlayerNode`, scheduling interleaved PCM16 buffers with bounded queued audio to match Moonlight's reference audio renderer contract more closely
- `VideoPacketDecryptor` and `AudioPacketDecryptor` implement the current encrypted-media ingress path using the Sunshine-compatible packet layouts documented in `docs/binary/VIDEO_PACKET_HEADERS.md` and `docs/binary/AUDIO_PACKET_HEADERS.md`
- `SessionRuntimeFactory` now auto-wires those decryptors when the negotiated session enables video or audio encryption
- `UDPChannelPacketSource` now emits periodic Sunshine-compatible media ping packets when the negotiated channel descriptor carries `pingPayload`

## Usage

```swift
#if os(macOS)
let displayCapabilities = await MainActor.run {
    NSScreen.main.map(MetalPresentationEDRCapabilities.init(screen:))
}
#elseif os(iOS)
let displayCapabilities = await MainActor.run {
    MetalPresentationEDRCapabilities(screen: UIScreen.main)
}
#else
let displayCapabilities: MetalPresentationEDRCapabilities? = nil
#endif

try await AppleMediaComponents.attachRecommendedPlaybackComponents(
    to: session,
    device: device,
    layer: metalLayer,
    preferredDecodeMode: configuration.preferredDecodeMode,
    softwareFallbackVideoDecoder: softwareDecoder,
    presentationConfiguration: MetalPresentationConfiguration(
        contentMode: .stretch,
        dynamicRangeMode: .automatic,
        edrCapabilities: displayCapabilities
    )
)
```

## DX Constraints

- production code should default to hardware decode
- software decode must be selectable as a fallback, not the first path
- apps should never need to coordinate decode and render manually
- Apple-specific helpers should keep `CAMetalLayer` ownership at the render boundary instead of leaking it through session core
