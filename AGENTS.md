# AGENTS.md

Instructions for agents working in this repository.

## Project Intent

- Build a pure Swift Moonlight-compatible client stack for Apple platforms.
- Target iOS, iPadOS, macOS, and visionOS.
- Production rendering backend is Metal.
- Preferred decode path is hardware-first with software fallback.
- v1 host targets are Sunshine and Apollo.
- v1 input must include physical controller support, including Xbox and DualSense.

## License And Clean-Room Constraints

- The project license is MIT.
- Do not copy, paste, or mechanically port GPL code from reference repositories.
- `refs/` exists for behavioral study only.
- Use references to understand protocol behavior, interoperability quirks, and missing details.
- When behavior comes from references instead of public docs, record it in `docs/OBSERVED_BEHAVIORS.md` and, when Apollo-specific, also in `docs/APOLLO_COMPATIBILITY.md`.
- Preserve a clean-room implementation style. Prefer describing behavior in plain English first, then implement idiomatic Swift.
- Keep third-party Apple dependencies reproducible inside the repo. For Opus, use the checked-in XCFramework rebuilt by `scripts/build-opus-xcframework.sh`, not a machine-local package manager.

## Source Of Truth

Before changing code, follow the docs:

- `docs/SPEC.md`
- `docs/ARCHITECTURE.md`
- `docs/HEADLESS_TESTING.md`
- `docs/TEST_PLAN.md`
- `docs/FIXTURES.md`
- `docs/BINARY_LAYOUTS.md`
- `docs/api/*.md`
- `docs/protocol/*.md`
- `docs/binary/*.md`

If code and docs conflict:
- do not silently pick one
- update docs and code together, or stop and clarify the conflict

## Implementation Rules

- Keep public APIs task-oriented and Swift-native.
- Do not expose packet-shaped APIs to app-level consumers unless a doc explicitly requires it.
- Keep protocol logic, transport, decode, rendering, and UI separated.
- Keep UIKit/AppKit/SwiftUI out of protocol-heavy modules.
- Use actor-safe, `async`-first APIs for client/session surfaces.
- Prefer explicit types and state machines over boolean-heavy flow control.
- Do not introduce fake versioned names like `FooV1` unless there is an actual parallel versioning strategy in the codebase.
- Avoid unnecessary product prefixes in internal code names when the module context already makes ownership obvious.
- Prefer complete, coherent subsystem slices over placeholder code that only exists to be rewritten immediately.
- If `@unchecked Sendable` is necessary, keep the blast radius small and document the safety invariant at the declaration site.

## Testing Rules

- Headless testability is required.
- Core logic must not require a visible window, real speakers, or real controller hardware.
- Introduce abstractions for transport, clock, decoder, renderer, audio sink, and input sources before binding to platform implementations.
- Add or update fixtures when implementing undocumented behavior.
- Golden packet tests belong with encoder/decoder work.
- Sunshine smoke tests should use null renderer/audio sink by default.

## Reference Usage

- Relevant references live under `refs/`.
- Prefer local `refs/` sources over web lookups when the needed code or docs already exist locally.
- Treat them as behavioral references only.
- Do not mirror upstream file layout just because a reference repo does.
- Do not import naming conventions wholesale when a better Swift API exists.
- If a hidden behavior matters for interoperability, document it before or while implementing it.

## Protocol Work

Before implementing a protocol-heavy area, confirm the corresponding docs exist and are current:

- Pairing: `docs/protocol/PAIRING.md`
- Host info and app list: `docs/protocol/HOST_INFO_AND_APPS.md`
- Session negotiation: `docs/protocol/SESSION_NEGOTIATION.md`
- Channel establishment: `docs/protocol/CHANNEL_ESTABLISHMENT.md`
- Input encoding: `docs/protocol/INPUT_ENCODING.md`
- Video transport: `docs/protocol/VIDEO_TRANSPORT.md`
- Audio transport: `docs/protocol/AUDIO_TRANSPORT.md`

Before implementing exact binary details, update the matching file in `docs/binary/`.

Control-channel parsing and message semantics are documented in:
- `docs/binary/CONTROL_MESSAGES.md`

When adding transport runtime code:
- keep packet sources separate from parsers and depacketizers
- prefer a real packet source plus deterministic tests over parser-only glue

## DX Rules

- Optimize for a clean developer-facing API first.
- Public usage should resemble the APIs in `docs/api/`.
- Do not force callers to manually orchestrate low-level handshake steps.
- Keep advanced behavior configurable, but do not make the common path verbose.

## Delivery Rules

- Prefer small, coherent commits and patches.
- Update docs when adding new behavior, quirks, or packet knowledge.
- Do not mark placeholder docs as complete unless they actually contain the required detail.
- If implementation is blocked by missing binary details or fixtures, add the doc stub or inventory entry first instead of guessing in code.
- Do not present temporary internal packet layouts as final protocol work. Be explicit about what is real, what is partial, and what still needs replacement with Moonlight-compatible behavior.
- When moving from scaffold code to real protocol code, replace the temporary path decisively instead of layering more fake abstractions on top.
- When upgrading Opus, update the rebuild script and regenerate `Vendor/COpus.xcframework` instead of switching back to `pkg-config`.

## First Implementation Order

Start in this order unless there is a strong documented reason to deviate:

1. Core shared types, errors, metrics, and state machine
2. Host models, host store, identity store, and compatibility profile types
3. Public client/session API skeleton matching `docs/api/`
4. Transport, clock, renderer, decoder, audio sink, and input source protocols
5. Null and recording test doubles for headless tests
6. Pairing module skeleton and transcript-driven tests
7. Host refresh and app list parsing with fixtures
8. Input semantic model and encoder interfaces
9. Video/audio pipeline boundaries
10. Sunshine smoke-test harness

Do not start with:
- UI screens
- direct RTSP/socket implementation before abstractions exist
- packet encoder details before the corresponding `docs/binary/` file is updated
