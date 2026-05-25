# Input Encoding Protocol

This document defines how semantic input events become host protocol packets.

Status:
- required for interactive streaming
- heavily observed from references

References:
- `refs/moonlight-common-c/src/Limelight.h`
- `refs/moonlight-common-c/src/InputStream.c`
- `refs/moonlight-ios/Limelight/Input`
- `refs/sunshine/src/input.cpp`
- `refs/apollo/src/input.cpp`

## Goal

App code sends semantic events:

```swift
try await session.send(.mouse(.relativeMove(dx: 8, dy: -2)))
try await session.send(.controller(.stateChanged(state)))
```

Encoder code owns:
- packet type selection
- normalization
- clamping
- batching where appropriate
- host quirk handling

## Canonical Event Model

Use the semantic model in:
- `docs/api/INPUT_API.md`

No module outside `Input` may construct binary packets directly.

## Mouse Rules

Support:
- relative move
- absolute move
- buttons
- vertical scroll
- horizontal scroll

Implementation rules:
- relative move is the default pointer path for trackpad-like interaction
- absolute move uses normalized unit coordinates and is converted by the encoder
- queued mouse motion should be coalesced before transport send:
  - relative deltas accumulate into the latest pending packet
  - absolute motion keeps only the newest pending position
- pending mouse motion must be flushed before button packets so clicks land at the newest pointer position
- session-level integrations should call `MoonlightSession.flushPendingInput()` before focus/capture transitions or controlled teardown if pending coalesced pointer state must be delivered deterministically
- high-resolution scroll should be preferred when supported

Observed compatibility notes:
- host handling of absolute coordinates is touch-port sensitive
- absolute mouse packets send `width`/`height` as `reference - 1` while preserving the full reference plane for `x/y`, matching Moonlight's edge-reach workaround
- Sunshine has special ordering behavior around absolute left-click and right-click interactions
- Apollo enforces per-client input permissions by input family
- Apollo and Sunshine differ in touch-port coordinate transforms
- direct mouse surfaces should suppress duplicate absolute positions from focus/modifier churn
- encoder logic must keep host-specific mouse quirks outside app code

## Keyboard Rules

Support:
- key down
- key up
- text input

Implementation rules:
- semantic key codes must be layout independent
- text input is not equivalent to physical key presses
- modifier normalization and synthetic shortcut behavior belong in the encoder layer

## Touch Rules

Support:
- touch down
- touch move
- touch up

Implementation rules:
- normalized coordinates are `0...1`
- pressure/radius/rotation must be clamped into the representable protocol range
- unsupported values must degrade predictably

## Controller Rules

Support in v1:
- controller arrival/connected
- controller disconnect
- state updates
- Xbox mapping
- DualSense mapping

Deferred but model now:
- touchpad
- motion
- battery
- rumble, trigger rumble, LED, adaptive-trigger, and motion-report feedback

Implementation rules:
- all device-specific controllers must map into a canonical controller state
- packet encoding depends on host protocol version and capability flags
- controller identity numbers must remain stable within a session
- host-originated controller feedback must be surfaced as typed session events before platform-specific haptics or LED adapters consume it
- authorization failures from Apollo permission gates must be surfaced distinctly from transport errors

## Required Swift Types

```swift
public protocol InputEncoder: Sendable {
    func encode(_ event: InputEvent, context: InputEncodingContext) throws -> [EncodedInputPacket]
}

public struct InputEncodingContext: Sendable {
    public var hostProfile: HostCompatibilityProfile
    public var streamViewport: CGSize
    public var absoluteReferenceWidth: Int16
    public var absoluteReferenceHeight: Int16
}
```

Current implementation note:
- `InputEncodingContext(host:negotiatedSession:)` derives `hostProfile` from the refreshed host and absolute reference dimensions from the negotiated video format.
- Sunshine and Apollo touch-port transforms are host-side state, so the client sends touch/pen coordinates as normalized client-surface packet fields rather than trying to reproduce hidden host touch-port offsets locally.
- Absolute mouse coordinates use the negotiated stream viewport reference plane and send `reference - 1` packet dimensions for the host-side edge workaround.
- `HostInputCoordinateOracle` provides a headless model of the observed Sunshine/Apollo host-side touch-port transform so tests can distinguish packet-encoding bugs from host geometry behavior.
- `InputSenderConfiguration.mouseMotionDeliveryPolicy` controls transport timing only. It must not change packet layout or coordinate mapping. The default is Moonlight-style 1 ms coalescing; immediate delivery should be treated as an opt-in diagnostic or sparse-pointer mode.

## Headless Test Cases

- mouse relative move encoding
- mouse absolute move encoding
- keyboard key down/up encoding
- UTF-8 text event encoding
- touch packet encoding
- Xbox state encoding
- DualSense state encoding
- controller arrival packet encoding
- regression fixture for Sunshine-specific absolute mouse behavior
- Sunshine/Apollo host-side absolute and touch coordinate oracle fixtures
