# Architecture

This document defines the codebase shape before protocol-heavy implementation starts.

## Design Goals

- clean Swift-first API
- minimal leakage of protocol details into app code
- strict separation between transport, session orchestration, decode, and rendering
- headless-first testability
- Metal-only production rendering on Apple platforms

## Package Layout

The folders below are groups inside the `SwiftMoonlight` target. They are not
separate Swift modules.

- `API/`: public client and session workflows, runtime setup, and the headless
  `Harness/` configuration, report, and runner.
- `Core/`: host, pairing, stream, session, metrics, and controller feedback
  types, plus errors and the state machine.
- `Dependencies/`: protocols for clocks, stores, transport, media, and input.
- `Input/`: input types, encoding, dispatch, and controller adapters. The
  GameController adapter is in `AppleGameControllerSource.swift`.
- `Media/Audio/`, `Media/Video/`, `Media/Rendering/`, and `Media/Transport/`:
  audio and video packet handling, decoding, rendering, and shared RTP parsing.
  `MediaPipeline`, media types, crypto, and test decoders remain at `Media/`.
  Audio separates `Transport/`, `Decoding/`, and `Playback/`. Rendering separates
  `Frames/`, `Color/`, `Presentation/`, `Effects/`, and `Shaders/`.
  The layer target, display callback owner, geometry, and embedded shader source
  have separate files. Decoder pointer storage is separate from the public Opus
  actor, and the PCM bridge is separate from playback queue management.
- `Network/HTTP/`, `Network/UDP/`, `Network/RTSP/`, `Network/Control/`, and
  `Network/Discovery/`: live transport and discovery implementations.
- `Protocol/Pairing/`, `Protocol/RTSP/`, `Protocol/Control/`, `Protocol/Host/`,
  and `Protocol/Session/`: protocol rules, parsers, and handshake services.
- `Storage/`: file and Keychain stores.
- `TestSupport/`: clocks, stores, media, input, and transport test doubles.

The `SwiftMoonlightCapture` target groups configuration, reports, image
analysis, media adapters, and its runner. The macOS `SwiftMoonlightTestApp`
target groups settings, its model, and views. Tests use topic folders under
`Tests/SwiftMoonlightTests/`. Media tests mirror audio, video, rendering, and
transport groups; their shared fixtures and pipeline tests stay at `Media/`.

The library builds for visionOS with the shared client, network, video, audio,
Metal, and GameController code. Opus decoding uses Apple AudioToolbox on all
Apple targets, without a bundled codec library. A visionOS app owns its window or
spatial presentation surface and passes a `CAMetalLayer` to the library when
it uses the Metal renderer.

## Dependency Direction

The dependency graph should stay one-way:

- App/UI depends on high-level `Client`
- `Client` depends on `Hosts`, `Pairing`, `Session`
- `Session` depends on `Transport`, `Input`, `Video`, `Audio`
- `Video` depends on `Rendering` only through a protocol
- no protocol module should depend on UIKit/AppKit/SwiftUI directly

Current implementation note:
- launch, RTSP negotiation, and channel establishment are now composed behind a bootstrap service instead of being left as disconnected subsystem sketches
- RTSP now has both message-level parsing/planning and a live TCP transport implementation
- incoming control-channel parsing is now isolated behind `ControlMessageParser` and `ControlChannelService`, with a dedicated transport seam
- encrypted control packet framing is isolated behind `ControlPacketCrypto` so the message parser stays focused on plaintext packet semantics
- packet-source-driven stream pumping is now isolated behind `SessionRuntime`, rather than being embedded in `MoonlightSession`
- negotiated channel descriptors can now be turned into live UDP control/input/media endpoints through `ChannelSocketFactory`
- prepared runtimes now own both the `SessionRuntime` and its channel sockets, with deterministic teardown through `PreparedSessionRuntime.stop()`
- host refresh now materializes `HostCompatibilityProfile`, `HostQuirkSet`, and inferred `HostCapabilities`
- a headless `IntegrationHarness` now exists in Sources and reuses the public client/session API
- controller input now has a dedicated runtime boundary through `ControllerSource`, `PollingControllerSource`, and `ControllerSessionBridge`
- host discovery now has a dedicated production boundary through `HostDiscovery` and `BonjourHostDiscovery`

## Core Interfaces

These are the minimum boundaries required before real implementation:

- `Clock`
- `HostStore`
- `HostDiscovery`
- `IdentityStore`
- `PairingClient`
- `SessionClient`
- `ControlChannel`
- `VideoChannel`
- `AudioChannel`
- `InputChannel`
- `VideoDecoder`
- `FrameRenderer`
- `AudioSink`
- `ControllerSource`

## Compatibility Layer

Sunshine and Apollo differences must be isolated behind:

- `HostCompatibilityProfile`
- `HostCapabilities`
- `HostQuirkSet`

No other module should hard-code host names or branch on them casually.

Current implementation note:
- Apollo quirks are currently modeled as explicit compatibility flags rather than scattered host-name checks
- capability inference is still heuristic and should be refined as live Sunshine/Apollo fixtures improve

## DX Rule

Public app-facing API should be task-oriented, not protocol-oriented.

Good:
- `client.pair(with:host,pin:)`
- `client.fetchApps(for:host)`
- `session.send(.mouseMove(...))`

Bad:
- forcing app code to manually sequence handshake endpoints
- exposing packet types as the primary public API
