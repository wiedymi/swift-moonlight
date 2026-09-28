# Session Negotiation Protocol

This document defines app launch, session parameter negotiation, and stream startup.

Status:
- required for all streaming
- fixture-driven launch-response parsing is implemented
- RTSP message framing, setup-response parsing, and request planning are implemented
- a live socket-backed RTSP transport exists
- encrypted `rtspenc://` RTSP transport is implemented using the negotiated remote-input key
- Sunshine SDP encryption flag parsing is implemented
- channel planning and establishment are implemented through transport abstractions
- runtime encryption metadata now flows from launch + RTSP negotiation into session bootstrap
- concrete channel transports still remain partial

References:
- `refs/moonlight-common-c/src/Limelight.h`
- `refs/moonlight-common-c/src/Misc.c`
- `refs/moonlight-common-c/src/SdpGenerator.c`
- `refs/moonlight-common-c/src/Connection.c`
- `refs/sunshine/src/nvhttp.cpp`
- `refs/sunshine/src/rtsp.cpp`
- `refs/apollo/src/nvhttp.cpp`
- `refs/apollo/src/rtsp.cpp`

## Goal

Expose one clean operation:

```swift
let session = try await client.openSession(
    hostID: host.id,
    appID: app.id,
    configuration: config
)
```

## Responsibilities

Session negotiation must:
- validate the requested `StreamConfiguration`
- map it into host launch parameters
- request app launch or desktop session
- capture the RTSP session URL
- negotiate stream parameters
- establish control, video, audio, and input channels

Compatibility note:
- Apollo supports additional launch or session policy such as input-only sessions, virtual-display-related behavior, and client-specific display mode overrides.

## Stream Configuration Contract

Required fields:
- resolution
- frame rate
- bitrate
- dynamic range preference
- codec preference order
- audio mode
- decode mode preference
- control encryption preference
- video encryption preference
- audio encryption preference
- attached gamepad mask and gamepad persistence preference

Rules:
- hardware decode is preferred by default
- if hardware decode is unavailable for the negotiated codec, software fallback may activate when allowed by configuration
- final negotiated settings must be emitted as a session event
- resolution is launch-time configuration in the current stack; local window resizing does not renegotiate host stream dimensions without starting a new session
- app integrations that need Apollo virtual displays to follow local window size should use `MoonlightClient.restartSession(...)` to stop/cancel/relaunch with a new requested resolution until a real mid-stream renegotiation path exists
- client-side validation rejects invalid launch inputs before host lookup or launch side effects:
  - resolution outside `320x180...7680x4320`
  - frame rate outside `1...240`
  - bitrate outside `1...500000` Kbps
  - empty video codec preference
- after host refresh, host-aware validation rejects:
  - codec preferences with no overlap with `ServerCodecModeSupport`
  - HDR requests when the host does not advertise HEVC Main10 or AV1 Main10 support
  - hardware-only decode when the host profile says hardware decode is unavailable
  - above-4K requests unless the requested host-supported codec set includes HEVC or AV1

## Negotiation Stages

### Stage 1: Launch Request

Purpose:
- ask the host to start the selected app or desktop
- send the launch parameters that affect the resulting stream

Required outputs:
- acceptance or rejection
- RTSP/session URL when available

### Stage 2: RTSP Setup

Purpose:
- negotiate media session details
- prepare the control/video/audio/input flows

Rules:
- RTSP setup and any encryption wrapper must remain encapsulated in `SessionControl` and `Transport`
- app-facing code should never manipulate RTSP messages directly

### Stage 3: Channel Establishment

Purpose:
- open control, video, audio, and input channels
- move session state to `streaming` only after minimum viability is met

Minimum viability:
- control connected
- input channel ready
- at least one media channel negotiated successfully

Apollo note:
- do not assume all successful launches are full audio/video sessions; Apollo has an input-only mode path

## Required Swift Types

```swift
public struct NegotiatedSession: Sendable {
    public var hostID: HostID
    public var appID: RemoteApp.ID
    public var rtspSessionURL: String
    public var videoFormat: VideoFormat?
    public var audioFormat: AudioFormat?
    public var remoteInputSecrets: RemoteInputSecrets?
    public var encryptionFeatures: SessionEncryptionFeatures
    public var isInputOnly: Bool
    public var channels: [EstablishedChannel]
}
```

Current implementation:
- `LaunchQueryBuilder` maps `StreamConfiguration` and identity into Sunshine/Apollo-compatible `/launch` query items
- `LaunchQueryBuilder` emits `surroundAudioInfo` as `channelMask << 16 | channelCount`, matching the reference-client launch query shape. It must not include Moonlight's internal `0xCA` audio-configuration magic byte.
- HDR launch queries include `hdrMode=1` plus `clientHdrCapVersion`, `clientHdrCapSupportedFlagsInUint32`, `clientHdrCapMetaDataId`, and `clientHdrCapDisplayData` from `HDRLaunchCapabilities`
- `StreamConfiguration.playAudioOnHost` is emitted as `localAudioPlayMode`, matching Moonlight's user-facing host-audio playback setting
- `StreamConfiguration.attachedGamepadMask` is emitted as both `remoteControllersBitmap` and `gcmap`, and `StreamConfiguration.persistGamepadsAfterDisconnect` is emitted as `gcpersist`, matching the controller launch-query shape used by reference Moonlight clients
- launch queries emit `additionalStates=1` for reference-client parity
- `LaunchResponseParser` parses Sunshine/Apollo `/launch` and `/resume` XML responses
- `LaunchSessionService` composes the query builder, transport, and response parser behind the `SessionService` protocol and carries remote-input key material into `NegotiatedSession`
- production launch fails before the request if random remote-input key creation fails
- `RTSPMessageParser` parses RTSP requests and responses from wire text
- `RTSPRequestFactory` and `RTSPRequestPlanBuilder` build DESCRIBE, SETUP, ANNOUNCE, and PLAY requests
- `RTSPSessionInfoParser` extracts `Session`, `Transport.server_port`, `X-SS-Ping-Payload`, and `X-SS-Connect-Data`
- `RTSPDescribeInfoParser` extracts Sunshine encryption feature flags from the DESCRIBE SDP body
- `SessionBootstrap` now derives the concrete `VideoFormat` from the requested stream configuration when launch did not already provide one; DESCRIBE SDP is currently used for encryption and audio capability hints rather than as the source of truth for the selected video codec
- `RTSPAnnounceSDPBuilder` emits the Gen 5+ Sunshine/Apollo fields parsed by the reference hosts for audio packet duration, audio/video QoS, FEC, configured bitrate, dynamic range, color-space mode, and reference-frame policy
- the advertised Moonlight FEC-status feature flag is backed by runtime `0x5502` frame FEC status reports when a FEC-described video frame becomes unrecoverable
- `RTSPNegotiationService` executes a fixture-driven RTSP negotiation sequence and returns describe-derived encryption metadata
- `NetworkRTSPTransport` provides a live TCP RTSP transport implementation for both `rtsp://` and `rtspenc://`
- `ChannelPlanBuilder` and `ChannelEstablishmentService` derive and establish control/input/video/audio channels
- `SessionBootstrap` composes launch + RTSP + channels into one bootstrapped session path and computes the enabled encryption features for runtime use
- `MoonlightClient.restartSession()` validates replacement stream configuration before stopping the existing runtime or cancelling the host app, then returns a replacement session plus prepared runtime for the app to attach media components before starting packet ingest
- it validates `status_code`
- it extracts `sessionUrl0`
- it maps non-200 responses to `launchRejected`
- `MoonlightClient.openSession()` can now use a bootstrap service and carry established channels in `NegotiatedSession`

## Errors

Map separately:
- `session.launchRejected`
- `session.invalidLaunchResponse`
- `session.rtspSetupFailed`
- `session.channelEstablishmentFailed`
- `session.unsupportedConfiguration`

## Headless Test Cases

- open session against Sunshine
- open session against Apollo
- fail cleanly on rejected app launch
- emit negotiated format snapshot
- stop cleanly after short observation window

Current gap:
- the RTSP transport has URL/session validation coverage, but not a stable end-to-end live socket integration test yet
