# Video and Audio API

This document defines the decode, render, and playback boundaries.

## Video Pipeline

Stages:
- packet ingestion
- depacketization
- access-unit reconstruction
- decode submission
- decoded frame delivery
- renderer handoff

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
- `MetalPresentationConfiguration(contentMode:dynamicRangeMode:edrCapabilities:preferredFrameRate:)` controls how decoded frames are mapped into the `CAMetalLayer`
- `MetalLayerTarget` receives decoded frames without waiting for a drawable. A `CAMetalDisplayLink` callback submits the newest decoded frame to its drawable. Older decoded frames can be replaced; encoded frames still decode in order. The newest frame remains available for resize redraws. An unchanged frame is not submitted again after a fade ends.
- Render submission latency ends when the renderer accepts a decoded frame. It does not include the later display callback, GPU work, or screen presentation.
- On iOS, `preferredFrameRate` supplies the stream rate to the display link, limited to the current screen maximum. The system can select a different display rate.
- `.stretch` is the default and fills the whole layer; use it when input is normalized against the whole surface or the stream is relaunched to match the local surface size
- `.aspectFit` preserves frame aspect with letterboxing or pillarboxing
- `.aspectFill` preserves frame aspect while cropping overflow
- `.automatic` is the default dynamic-range mode. It uses an SDR `bgra8Unorm` layer for SDR streams and an EDR `rgba16Float` layer with extended-linear shader output for HDR streams when display capabilities are not supplied
- when `edrCapabilities` is supplied, `.automatic` uses EDR for an HDR stream only if the display reports EDR headroom; this lets apps keep SDR tone mapping on displays without EDR
- `.standardDynamicRange` always uses the SDR layer and tone-maps HDR frames in the shader
- `.extendedDynamicRange` always uses the EDR layer; apps can use it when they manage the display policy themselves
- `MetalPresentationEDRCapabilities(screen:)` can be built from `NSScreen` or `UIScreen` on the main actor so app code does not need to duplicate Apple EDR headroom checks
- `MetalPresentationGeometry` exposes the matching `contentRect`, normalized `sourceRect`, and `normalizedFramePoint(forDrawablePoint:)` mapping for absolute pointer input
- absolute pointer mapping must use the same presentation geometry chosen by the app, otherwise host cursor coordinates can drift from the pixels shown to the user

### Spatial scaling and resize presentation

`MetalPresentationConfiguration.upscalingMode` defaults to `.linear`.
`.metalFXSpatial` converts the decoded image to an RGB texture at its source
size, then scales it to the visible picture size before presentation. SDR uses
perceptual BGRA; EDR uses HDR RGBA16Float. Fit, fill, and stretch use the same
geometry as standard presentation. Fill scales the complete picture before
cropping, so a narrower drawable does not disable upscaling. Downscaling, unsupported devices, missing
MetalFX frameworks (including iOS Simulator), or resource allocation failure
use standard scaling. MetalFX does not change the negotiated stream size or
bitrate and does not receive game depth or motion data.

`background` defaults to `.black`. `.blurred` fills unused video space with a
blurred, darkened copy of the frame and a vertical gradient. The blur uses a
texture with a maximum side of 256 pixels and a Gaussian filter. This adds a
conversion pass and small background textures; it avoids a full-size blur.
All foreground shaders limit sampling to the picture bounds to prevent a
scaled triangle from extending frame edges into empty space.

`MetalLayerTarget.beginTransition()` holds the picture as a blurred background.
Frames from the current stream do not end this transition. After `prepare`
configures the next stream, its first frame starts a 250 ms fade to a clear
picture. `endTransition()` cancels a pending adjustment and restores the
current picture with the same fade. A drawable size change also triggers a
short blur and fade with `.blurred` backgrounds, including when stream resolution is fixed.
`setPreferredFrameRate(_:)` updates the iOS display-link rate when a retained
target is reused with a different stream rate. The app must limit this rate
to the current screen maximum.

The target normally stops its display link and releases its last decoded
frame on `teardown`. An app that preserves presentation across session
restarts can own one target through an app-level `MetalFrameTarget` adapter:
forward `prepare` and `present`, preserve it during session teardown, and call
the real target's `teardown` when the stream view closes. The app must also
stop it if initial attachment fails. This is an explicit lifetime requirement.

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
    func play(_ buffer: PCMBuffer) async -> AudioPlaybackResult
    func teardown() async
}

public enum AudioPlaybackResult: Sendable {
    case accepted
    case dropped
}
```

Production implementations:
- `OpusDecoder` (Apple AudioToolbox, no bundled libopus)
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
- `BoundUDPSocket` waits for read events while idle. Closing the socket wakes a waiting receive call.
- `SystemAudioSink` is now implemented on Apple platforms via `AVAudioEngine` and `AVAudioPlayerNode`, scheduling interleaved PCM16 buffers with bounded queued audio to match Moonlight's reference audio renderer contract more closely
- `AudioPlaybackResult.accepted` means the sink accepted a buffer. It does not mean sound reached the speakers. `playedAudioBuffers` counts accepted buffers. `SystemAudioSink` reports `.dropped` if the queue is full or playback setup fails.
- `VideoPacketDecryptor` and `AudioPacketDecryptor` implement the current encrypted-media ingress path using the Sunshine-compatible packet layouts documented in `docs/binary/VIDEO_PACKET_HEADERS.md` and `docs/binary/AUDIO_PACKET_HEADERS.md`
- `SessionRuntimeFactory` now auto-wires those decryptors when the negotiated session enables video or audio encryption
- `UDPChannelPacketSource` now emits periodic Sunshine-compatible media ping packets when the negotiated channel descriptor carries `pingPayload`

## Usage

```swift
try await AppleMediaComponents.attachRecommendedPlaybackComponents(
    to: session,
    device: device,
    layer: metalLayer,
    preferredDecodeMode: configuration.preferredDecodeMode,
    softwareFallbackVideoDecoder: softwareDecoder,
    presentationConfiguration: MetalPresentationConfiguration(contentMode: .stretch)
)
```

Apps that know the active display can pass `MetalPresentationEDRCapabilities(screen:)` to retain SDR tone mapping when the display has no EDR headroom. Without these capabilities, an HDR stream uses an EDR layer. The display can then clip values above its EDR limit; the library does not apply display-aware tone mapping in this case.

## DX Constraints

- production code should default to hardware decode
- software decode must be selectable as a fallback, not the first path
- apps should never need to coordinate decode and render manually
- Apple-specific helpers should keep `CAMetalLayer` ownership at the render boundary instead of leaking it through session core

`MetalLayerTarget.currentPresentationDiagnostics()` returns the last GPU
submission's source, picture, and drawable sizes, output range, and actual
scaling status. Status distinguishes standard scaling, MetalFX, a size that
does not need upscaling, standard fallback, and a blur transition. These are
submission facts; they do not measure GPU completion or screen presentation.

Blur presentation ignores picture borders smaller than two drawable pixels on
each side. These small borders stay black, avoiding a Gaussian filter for
codec rounding differences. Larger borders and resize transitions still use
blur. A cached blurred texture is reused while the decoded frame object stays
the same. A weak frame reference prevents an old object address from matching
a later frame after the old frame is released. A new frame is filtered even
when its timestamp is unchanged.

## Native Opus Decoder

`OpusDecoder` keeps the same public actor API and signed 16-bit interleaved PCM
output. One actor owns an `AudioConverter` and its negotiated configuration.
Configuration is replaced only after converter creation, cookie setup, and
priming setup succeed.

The decoder supplies one raw Opus multistream packet per synchronous input
callback. The packet bytes and packet description have stable owned storage,
retained until the next input callback, converter reset, or converter disposal.
Returning from `AudioConverterFillComplexBuffer` does not end this lifetime.
The OpusHead cookie carries channel count, streams, coupled streams,
and the negotiated output mapping. Converter priming is zero so the first live
packet retains its full duration. Packet length follows the first stream's Opus
TOC, up to 120 ms. The most recent successful packet duration becomes the duration
used for later lost-packet recovery; before any valid packet, the negotiated
`samplesPerFrame` is used.

Empty payloads and explicit concealment packets supply one zero-byte compressed
packet with a frame count. This invokes the native decoder's lost-packet recovery;
it is not an end-of-stream signal. If the callback is called again during the same
decode call, it returns a temporary input-exhausted status. Decoder errors discard
partial converter state. Error messages contain status and frame counts, never
packet contents.

Native decoding is not a claim of hardware acceleration or lower CPU use.
Runtime support is checked when AudioToolbox creates and configures the converter.
There is no bundled software fallback.

## Swift 6 Layer Isolation

Create `MetalLayerTarget` and call `AppleMediaComponents.makeRenderer` or
`attachRecommendedPlaybackComponents` on the main actor. The layer reference is
main-actor isolated and needs no unchecked Sendable conformance. View resize,
layer setup, dynamic-range properties, and display-link setup all use the main
actor. Decode, pipeline state, and display callback work keep their existing
owners. This isolates shared UI state without moving per-frame GPU work onto
the main actor.

### Audio playback timing

`SystemAudioSink` requires `prepare` before playback. After teardown it drops late
buffers until explicitly prepared again; playback cannot restart the engine.
It collects 20 ms before starting playback and after an empty queue.
It derives queued frames from the player sample clock, without asynchronous buffer
completion tasks. The queue accepts up to 120 ms, including valid long Opus packets
and short recovered bursts. This adds about 20 ms at start; device latency is separate.
PCM sample rate and channel count must match the prepared format before bytes are copied.

### Video receive and decode work

Annex-B parsing scans borrowed bytes and copies only selected parameter sets or
final decoder sample bytes. It does not copy the full payload into an array or
allocate intermediate picture NAL buffers. Nonzero Data indices, escaped bytes,
empty NAL units, and three-byte start codes at the end are covered by tests.

Run `python3 scripts/benchmark-video-parsing.py` with the full Xcode toolchain to
compare the parser with revision `3051f020f6cfed454feaf729f206df1b27421940`.
It compiles both parsers with optimization, checks sample byte equality, and
reports the median of five runs of 400 iterations. Temporary sources and binaries
are removed. On the development Mac, the 187,500-byte synthetic picture measured
0.209 ms before and 0.014 ms after. These numbers cover parameter-set extraction
and sample conversion, not network receive, decode, GPU work, or stream FPS.

VideoToolbox submission enables asynchronous decompression. The caller awaits the
output callback without blocking a Swift worker. Ordered bounded pipeline
submission still controls frame order and backpressure.
