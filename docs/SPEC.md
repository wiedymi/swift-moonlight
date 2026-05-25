# Swift Moonlight Spec

This document defines the implementation contract for `swift-moonlight`.

It is not a wire-level standard for the wider ecosystem. It is the project's internal source of truth for:
- what behavior we implement
- what interoperability we require
- what parity target we are chasing
- what behaviors come from public docs versus observed references

## 1. Scope

Primary targets:
- iOS
- iPadOS
- macOS

Primary host target:
- Sunshine

Additional required host target:
- Apollo (Sunshine fork), to the extent supported by the HarmonyOS client behavior baseline

Initial parity baseline:
- the end-user feature set currently described by `refs/moonlight-harmonyos`

Known baseline features from HarmonyOS reference:
- encrypted pairing
- video streaming
- software decode fallback
- hardware decode
- audio playback
- virtual controller / touch controls
- Apollo compatibility target

Required v1 additions beyond the HarmonyOS README summary:
- physical controller support on Apple platforms
- Xbox controller support
- DualSense controller support

Deferred unless confirmed in the HarmonyOS implementation:
- rumble
- trigger rumble
- motion sensors
- keyboard/mouse edge-case parity
- HDR parity

## 2. Non-Goals

Non-goals for the first clean-room implementation:
- line-by-line compatibility with upstream source layout
- direct source translation from GPL references
- immediate support for every historical GameStream host variant
- UI parity with upstream clients

Explicitly out of initial host scope:
- legacy NVIDIA GameStream compatibility beyond what falls out naturally from Sunshine/Apollo interoperability

## 3. Architecture

The implementation should be split into separable modules with narrow interfaces:

- `Discovery`
  - find and enumerate hosts
  - persist host metadata

- `Pairing`
  - manage certificates/keys
  - execute pairing handshake
  - store trust state

- `SessionControl`
  - query host capabilities
  - negotiate launch/session parameters
  - own app launch and session lifecycle
  - isolate host-specific quirks behind a compatibility layer

- `Transport`
  - TCP/UDP sockets
  - packet parsing
  - encryption/authentication where required
  - packet pacing, jitter buffering, retransmit-related behavior where applicable

- `Video`
  - stream packet ingestion
  - elementary stream reconstruction
  - hardware decode path
  - software decode fallback
  - frame timing and delivery

- `Audio`
  - packet ingestion
  - decode
  - playback scheduling

- `Input`
  - touch / virtual controller
  - keyboard and mouse
  - game controller support
  - optional motion, battery, rumble, LEDs

- `Core`
  - session orchestration
  - state machine
  - metrics and error reporting
  - transport-loss accounting surfaced through session metrics

## 4. Interoperability Levels

Each feature must declare one of these levels:

- `Specified`
  - behavior is derived from public docs or protocol descriptions

- `Observed`
  - behavior is inferred from one or more reference implementations

- `RequiredForSunshine`
  - behavior is not well documented but is required to interoperate with Sunshine

When adding a behavior in `Observed` or `RequiredForSunshine`, record the evidence in `docs/OBSERVED_BEHAVIORS.md`.

## 5. Session Lifecycle

The implementation should support this lifecycle:

1. Discover or manually add host
2. Query host information
3. Pair if needed
4. Fetch app list
5. Launch app/session with negotiated parameters
6. Establish control, video, audio, and input channels
7. Stream until stop, disconnect, or failure
8. Tear down session cleanly
9. Allow reconnect where feasible

Host compatibility note:
- host-specific deviations between Sunshine and Apollo should be normalized behind compatibility adapters rather than spread across the session core

## 6. Pairing Requirements

The pairing module must:
- generate and persist client identity material
- execute encrypted pairing successfully against Sunshine
- execute encrypted pairing successfully against Apollo where behavior differs
- detect out-of-order or invalid handshake responses
- support unpairing
- fail closed on cryptographic validation errors

Headless acceptance criteria:
- can pair with a clean Sunshine instance
- can pair with a clean Apollo instance when configured
- can detect already-paired state
- can unpair and return to unpaired state

## 7. Video Requirements

The video module must:
- ingest packetized video data from the negotiated stream
- reconstruct decodable samples
- expose a hardware-first decode path using Apple frameworks
- expose a software decode fallback behind a testable abstraction
- surface decode statistics
- render decoded frames through Metal on Apple platforms

Rendering requirements:
- Metal is the required production rendering backend
- decoded frames should be presented through a Metal-compatible frame path
- rendering must remain separate from session/protocol logic
- a headless renderer or no-op renderer must exist for automated tests

Decode policy:
- hardware decode is the default and preferred path on Apple platforms
- software decode exists as a fallback for unsupported codec/device/runtime cases and for some test scenarios
- decode selection must be observable in metrics and logs

Headless acceptance criteria:
- parser/depacketizer can consume captured or simulated packets
- bitstream output is stable for golden fixtures
- decode path can be mocked in CI without a visible window

## 8. Audio Requirements

The audio module must:
- ingest streamed audio packets
- decode to PCM
- provide a pluggable render sink
- support a null sink for headless tests

Headless acceptance criteria:
- packet decode succeeds against fixtures
- PCM output matches reference expectations within defined tolerance
- continuous stream timing is validated without requiring speakers

## 9. Input Requirements

The input module must support at minimum:
- touch / virtual controller events
- keyboard events
- mouse movement and button events
- physical controller events
- Xbox controller mapping
- DualSense controller mapping

Later parity targets:
- full DualSense adaptive-trigger payload mapping
- live Xbox/DualSense feedback validation
- keyboard/mouse edge-case parity

Headless acceptance criteria:
- encode outbound input packets deterministically
- verify packets against captured Sunshine-visible behavior or approved fixtures

## 10. State Machine Requirements

Core state machine must be explicit and testable:
- `idle`
- `discovering`
- `pairing`
- `paired`
- `launching`
- `connecting`
- `streaming`
- `stopping`
- `failed`

Transitions must be driven by typed events, not ad hoc booleans.

## 11. Error Model

Errors should be structured and classified:
- network
- protocol
- crypto
- capability mismatch
- codec/decode
- audio render
- input
- host rejection
- timeout

Each user-visible failure should map to one stable error code plus debugging context.

## 12. Metrics and Tracing

Expose structured runtime metrics for:
- connection establishment times
- packet loss / reorder counters where measurable
- video decode latency
- audio underruns
- round-trip time where measurable
- reconnect attempts

These metrics must be available without UI so headless integration tests can assert on them.

Current implementation note:
- `session.metrics` now includes session-open timing, ENet-backed control RTT/loss telemetry where available, observed control/video/audio packet counters, audio concealment counters, reordered audio/video packet counters, video discontinuity counts, reconnect attempt counts, decode/render/playback counters, video/audio decode latency metrics, host-provided video processing latency metrics, audio underrun counts, and unexpected disconnect state
- RTT/loss telemetry is currently available only for control transports that implement `ControlTransportMetricsReporting`; non-ENet transports report nil metrics
- reconnect currently means bounded retry within the existing runtime/service/socket graph after transient read/decode failures; it is not a full host renegotiation or session-resume flow

## 13. Documentation Artifacts

Maintain these alongside implementation:
- `docs/FEATURES.md`
- `docs/OBSERVED_BEHAVIORS.md`
- `docs/TEST_PLAN.md`
- `docs/ARCHITECTURE.md`
- `docs/FIXTURES.md`
- `docs/APOLLO_COMPATIBILITY.md`
- `docs/BINARY_LAYOUTS.md`
- `docs/api/*.md`
- `docs/protocol/*.md`
- `docs/binary/*.md`

## 14. Implementation Order

Recommended order:

1. Pairing and host metadata
2. Session launch/control negotiation
3. Input packet encoding
4. Video packet parsing and fixture-based validation
5. Audio packet parsing and null-sink playback
6. End-to-end Sunshine integration harness
7. Apple-platform decode integration
8. Metal renderer integration
