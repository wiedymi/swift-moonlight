# Architecture

This document defines the codebase shape before protocol-heavy implementation starts.

## Design Goals

- clean Swift-first API
- minimal leakage of protocol details into app code
- strict separation between transport, session orchestration, decode, and rendering
- headless-first testability
- Metal-only production rendering on Apple platforms

## Proposed Package Layout

- `SwiftMoonlight/Core`
  - shared types
  - errors
  - metrics
  - state machine
  - clocks

- `SwiftMoonlight/Hosts`
  - host model
  - host persistence
  - discovery
  - compatibility profiles

- `SwiftMoonlight/Pairing`
  - client identity
  - certificate/key storage
  - pairing state machine

- `SwiftMoonlight/Session`
  - host info
  - app list
  - launch negotiation
  - session lifecycle

- `SwiftMoonlight/Transport`
  - TCP/UDP transport abstraction
  - request/response codecs
  - stream channels

- `SwiftMoonlight/Input`
  - semantic input model
  - protocol encoders
  - GameController adapters

- `SwiftMoonlight/Video`
  - depacketizer
  - decode abstraction
  - VideoToolbox decoder
  - frame queue

- `SwiftMoonlight/Rendering`
  - renderer abstraction
  - Metal renderer
  - null renderer

- `SwiftMoonlight/Audio`
  - depacketizer
  - decode abstraction
  - audio sink abstraction
  - null sink

- `SwiftMoonlight/TestSupport`
  - mocks
  - fixtures
  - loopback/fault transport

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
