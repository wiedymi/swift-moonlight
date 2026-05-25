# Apollo Compatibility

This document tracks all known or suspected Apollo-specific differences from Sunshine.

Status values:
- confirmed
- suspected
- unresolved
- not applicable

## Goal

Keep Apollo compatibility explicit and isolated so the session core does not accumulate scattered host checks.

Primary reference:
- `refs/apollo`

## Tracking Template

## Item Title

- Status:
- Area:
- Source:
- Behavior:
- Swift handling:
- Test coverage:

## Areas To Track

- host identification heuristics
- server info field differences
- app list field differences
- pairing flow differences
- launch parameter differences
- RTSP negotiation differences
- codec capability differences
- input behavior differences
- disconnect or teardown differences

## Current Policy

- prefer one canonical implementation path
- introduce compatibility quirks only when required by observed Apollo behavior
- every new Apollo-specific branch must be documented here and in tests

## Confirmed Differences

## Per-client permissions

- Status: confirmed
- Area: pairing, launch, input, app visibility
- Source:
  - `refs/apollo/src/nvhttp.cpp`
  - `refs/apollo/README.md`
  - live serverinfo from `apollo-host.local:47989`
- Behavior:
  - Apollo stores per-client permissions and does not treat all paired clients equally. Newly paired clients may receive reduced permissions instead of full launch/input rights.
  - Apollo can expose a `Permission` field in `serverinfo` even when `appversion` and `GfeVersion` otherwise look like a Sunshine-family GameStream server.
  - Apollo's plain HTTP `serverinfo` can report `Permission=0` and `PairStatus=0` for a saved paired certificate, while certificate-authenticated HTTPS `serverinfo` reports the actual paired state and per-client permission mask.
- Swift handling:
  - model client authorization failure separately from generic pairing success
  - expect `paired` and `allowed to launch/send input` to be different concepts on Apollo
  - add capability or authorization state to host-session logic
  - host-kind inference treats the presence of `Permission` as Apollo policy evidence before falling back to generic Sunshine-family heuristics
  - prefer authenticated HTTPS `serverinfo` when a secure port is known, with HTTP fallback for discovery and unpaired hosts
- Test coverage:
  - integration tests for paired-but-launch-denied and paired-but-input-denied scenarios
  - `hostRefreshTreatsApolloPermissionFieldAsApolloEvenWithSunshineVersionShape()`
  - `httpHostServiceFallsBackToPlainServerInfoWhenSecureServerInfoFails()`

## Per-client policy fields in persisted device state

- Status: confirmed
- Area: host metadata / compatibility
- Source:
  - `refs/apollo/src/nvhttp.cpp`
- Behavior:
  - Apollo persists device-specific fields beyond cert/name/uuid, including permission mask, display mode override, legacy ordering toggle, client-command permission, and always-use-virtual-display.
- Swift handling:
  - do not assume Apollo device records are equivalent to Sunshine device records
  - compatibility layer should treat Apollo as policy-rich host metadata
- Test coverage:
  - response parsing and compatibility-profile tests

## OTP-assisted pairing

- Status: confirmed
- Area: pairing
- Source:
  - `refs/apollo/src/nvhttp.cpp`
  - `refs/apollo/src/confighttp.cpp`
- Behavior:
  - Apollo adds one-time-pin support and `otpauth` handling on top of the pairing flow.
- Swift handling:
  - keep the normal PIN-based pairing path as baseline
  - model OTP as an Apollo-specific optional pairing mode, not the default cross-host path
  - implemented as `PairingAuth.otp(pin:passphrase:)` in the client and harness APIs
  - runtime pairing now includes Apollo `otpauth` on `getservercert`
- Test coverage:
  - query-construction coverage in `cryptoPairingClientServiceIncludesApolloOTPAuthOnGetServerCert()`

## Input-only sessions

- Status: confirmed
- Area: launch/session negotiation
- Source:
  - `refs/apollo/src/nvhttp.cpp`
  - `refs/apollo/src/rtsp.cpp`
  - `refs/apollo/src/process.cpp`
  - `refs/apollo/src/audio.cpp`
  - `refs/apollo/src/video.cpp`
- Behavior:
  - Apollo supports input-only mode and threads that state through launch, RTSP/session config, audio, and video handling.
- Swift handling:
  - session model should allow an input-only session mode in the future
  - v1 may defer full support, but negotiation code must not assume every launch produces normal audio/video streams
- Test coverage:
  - deferred feature tests; add parser and compatibility coverage first

## Visual target input validation

- Status: observed diagnostic gap
- Area: input/capture validation
- Source:
  - saved-paired Apollo desktop capture with `docs/input-visual-target.html`
- Behavior:
  - `swift-moonlight-capture` can open the pointer-reactive visual target page on an Apollo desktop through the Windows Run dialog when `SWIFT_MOONLIGHT_CAPTURE_INPUT_VISUAL_TARGET_URL` is set.
  - In the current local run, video/audio transport stayed healthy and input packets advanced.
  - With Apollo virtual desktop geometry, absolute packets can move and click the host but land outside the visual target region; the observed activation click opened a right-side launcher instead of the left-side target page.
  - A later Apollo virtual-display run fetched the target page from the Mac helper server, but the streamed display still showed only the virtual desktop wallpaper. This means Windows opened the browser on another monitor, so packet counters and target fetch logs were not sufficient evidence that the streamed display received the page.
  - A follow-up run with the experimental PowerShell helper command did not fetch the helper or target page, which means Win+R command execution is not reliable enough to be treated as a solved verifier path.
  - A relative visual probe can produce a generic decoded-frame delta, but the changed bounds may be unrelated desktop UI rather than the target page, so this is not proof of cursor synchronization.
- Swift handling:
  - do not treat packet-send success or generic frame deltas as sufficient Apollo cursor parity evidence
  - the visual target page now includes a high-contrast sentinel, and capture requires that sentinel to be visible before accepting target-region probe evidence
  - `SWIFT_MOONLIGHT_CAPTURE_INPUT_VISUAL_OPEN_HELPER_URL` is available as an experimental diagnostic path, but live Apollo evidence has not proven it reliable yet
  - keep exact visual-target expected-region validation as an open gate until a run shows the target page marker moving in the requested regions
  - use captured relative mouse mode for physical mouse input in the test app; reserve direct absolute mode for touch-like diagnostics until Apollo virtual-display offset handling is solved

## Virtual display and display-mode overrides

- Status: confirmed
- Area: launch/session negotiation
- Source:
  - `refs/apollo/src/nvhttp.cpp`
  - `refs/apollo/src/process.cpp`
  - `refs/apollo/src/display_device.cpp`
- Behavior:
  - Apollo adds per-client and per-launch virtual display behavior plus explicit display mode override handling.
- Swift handling:
  - keep these as Apollo-specific advanced host features
  - production launch defaults request `virtualDisplay=1` for Apollo-compatible hosts so the host creates a stream display matching the requested mode instead of reusing an arbitrary physical/multi-display desktop
  - do not bake manual display-mode override fields into the common v1 session API unless explicitly exposed as advanced options later
- Test coverage:
  - `productionLaunchDefaultsRequestApolloVirtualDisplay()`

## RTSP negotiation extensions

- Status: confirmed
- Area: RTSP/session negotiation
- Source:
  - `refs/apollo/src/rtsp.cpp`
  - `refs/sunshine/src/rtsp.cpp`
- Behavior:
  - Apollo extends session config handling with `input_only`, bitrate restoration for warp-like framerate scaling, and some helper/session management additions.
- Swift handling:
  - negotiated session model should tolerate Apollo-specific fields and adjusted bitrate semantics
  - do not assume Sunshine RTSP config is the full superset
- Test coverage:
  - negotiation fixture tests once Apollo fixtures exist

## Gen 5+ control-stream startup gates usable media delivery

- Status: confirmed
- Area: control stream / session establishment
- Source:
  - `refs/moonlight-common-c/src/Connection.c`
  - `refs/moonlight-common-c/src/ControlStream.c`
  - live Apollo host smoke run against stored paired host state
- Behavior:
  - Apollo can accept launch plus RTSP `PLAY` while still delivering zero control, video, and audio packets until the Gen 5+ control stream is actually started on the negotiated control port using the RTSP-provided connect data.
- Swift handling:
  - do not equate successful RTSP negotiation with a usable running session
  - implement the Gen 5+ control stream as a first-class transport stage instead of treating the control port as a raw best-effort UDP socket
- Test coverage:
  - live integration smoke currently reproduces this as `videoPacketsObserved=0` and `audioPacketsObserved=0`

## Input permission gating

- Status: confirmed
- Area: input
- Source:
  - `refs/apollo/src/input.cpp`
- Behavior:
  - Apollo gates outbound input handling by per-client permission masks across controller, mouse, keyboard, touch, and pen families.
- Swift handling:
  - input send failures on Apollo may be authorization failures rather than transport or protocol errors
  - session metrics and errors should be able to distinguish denied input
- Test coverage:
  - deferred until Apollo integration testing

## Touch coordinate behavior divergence

- Status: confirmed
- Area: touch / absolute input mapping
- Source:
  - `refs/apollo/src/input.cpp`
  - `refs/sunshine/src/input.cpp`
- Behavior:
  - Apollo’s touch-port and absolute-input coordinate handling differs materially from Sunshine. Sunshine applies additional logical touch-port scaling, while Apollo uses a simpler coordinate path tied to environment width and height.
- Swift handling:
  - absolute mouse packet encoding must use the same negotiated stream reference plane as presentation
  - touch and pen packets remain normalized client-surface packets for both hosts
  - do not pre-transform touch/pen packet bytes for Apollo; Apollo and Sunshine apply their divergent touch-port transforms after receiving the packet
  - `HostInputCoordinateOracle` models Apollo's physical environment-size path separately from Sunshine's logical touch-port scaling path for headless diagnostics
- Test coverage:
  - unit coverage for host-independent normalized touch/pen packet bytes
  - `hostInputCoordinateOracleModelsSunshineLogicalTouchPortScaling()`
  - `hostInputCoordinateOracleKeepsTouchNormalizedWhilePortsDiverge()`
  - live host cursor/touch validation is still needed

## Virtual display sizing is launch-time state

- Status: observed
- Area: Apollo virtual display
- Source:
  - live Apollo virtual-display testing
- Behavior:
  - Apollo can create a virtual display that follows the requested launch resolution.
  - Local stream-window resizing after launch changes only client presentation unless the client starts a new session with a new requested resolution.
- Swift handling:
  - direct pointer mapping uses the same full layer rectangle as the presented stream
  - the test app's `Window` resolution preset resolves to the stream window backing-pixel size before launch
  - mid-stream resolution renegotiation remains unimplemented at the protocol level
  - the test app watches stream-window backing-pixel size changes and performs a debounced restart through `MoonlightClient.restartSession(...)` when the `Window` resolution preset is active, so Apollo can recreate its virtual display at the new launch resolution
  - real app integrations can use `MoonlightClient.restartSession(...)` for the same validated stop/cancel/relaunch ordering without duplicating lifecycle code
- Test coverage:
  - integration

## HDR requests may produce mixed SDR and HDR startup frames

- Status: observed
- Area: HDR / video decode
- Source:
  - live Apollo capture against `apollo-host.local:47989`
- Behavior:
  - Apollo accepted an HDR stream request and produced 10-bit HEVC CoreVideo surfaces (`&xv0`) in live capture, but the control channel reported HDR mode disabled.
  - The same result persisted after adding Moonlight-style HDR client capability fields to the launch query.
  - The decoded frame metadata advertised `SMPTE_C` primaries, `ITU_R_709_2` transfer, and `ITU_R_601_4` YCbCr matrix rather than PQ/BT.2020 HDR metadata.
  - When VideoToolbox was allowed to choose its default output, the packed lossless `&xv0` surface produced visibly wrong Metal readback because the shader treated it like uncompressed P010.
  - After requesting uncompressed HDR output, VideoToolbox produced `x420` with the same SDR metadata, and Metal readback returned to the same small PNG delta range observed for SDR captures.
  - A later live HDR-required capture produced `x420` frames where the first decoded frame still carried SDR metadata, then Apollo sent an HDR-enabled control update and later decoded frames carried `SMPTE_ST_2084_PQ` transfer with BT.2020 primaries/matrix.
- Swift handling:
  - do not treat 10-bit decode surfaces alone as proof of active HDR presentation
  - evaluate color conversion per decoded frame, not once per launch, because Apollo can switch from SDR-tagged startup frames to PQ/BT.2020 frames after the session is already flowing
  - launch queries now include Moonlight-compatible HDR client capability fields in addition to `hdrMode=1`
  - VideoToolbox decode requests uncompressed `x420` for HDR streams so Metal receives a P010-style surface instead of packed lossless `&xv0`
  - Metal only falls back to BT.2020 when the decoded frame advertises PQ or HLG transfer metadata; HDR-requested frames that advertise SDR transfer stay on SDR matrix fallback unless CoreVideo provides a specific matrix attachment
  - headless HDR verification should use `SWIFT_MOONLIGHT_CAPTURE_REQUIRE_HDR=1` when the run must fail on 10-bit SDR output
  - a saved-paired Apollo HDR-required capture can still fail with `HDR mode changed: disabled` and only SDR-tagged `x420` frames; treat that as a host/display HDR activation failure, not as proof of broken true-HDR Metal presentation
- Test coverage:
  - unit
  - integration

## `continuousAudio` launch option is not handled by Apollo reference sources

- Status: confirmed
- Area: audio / launch
- Source:
  - `refs/sunshine/src/nvhttp.cpp`
  - `refs/sunshine/src/rtsp.cpp`
  - `refs/sunshine/src/audio.cpp`
  - `refs/apollo/src/nvhttp.cpp`
  - `refs/apollo/src/rtsp.cpp`
  - live Apollo capture against `apollo-host.local:47989`
- Behavior:
  - Sunshine stores the `/launch` `continuousAudio` flag and carries it into the audio capture configuration so quiet desktop sessions can keep producing audio packets.
  - The checked-in Apollo reference does not parse or carry `continuousAudio`, so a headless capture can observe zero audio packets when the host has no active audio source even though video/control/input are connected.
  - After fixing launch `surroundAudioInfo` to match reference Moonlight, a live Apollo audio-required capture still produced zero audio packets, which is consistent with the missing Apollo continuous-audio path rather than proof of an Opus decode failure.
- Swift handling:
  - continue emitting `continuousAudio=1` when requested, because Sunshine supports it and future Apollo versions may add it
  - treat Apollo `SWIFT_MOONLIGHT_CAPTURE_REQUIRE_AUDIO=1` failures as requiring a deterministic host-side audio source unless Apollo adds continuous-audio support
  - use audio decode/WAV evidence only when audio packets are actually observed
- Test coverage:
  - integration

## Repeated saved-pairing smoke runs can benefit from pre-launch cancel

- Status: observed
- Area: session lifecycle / test harness
- Source:
  - live Apollo smoke runs against `apollo-host.local:47989`
- Behavior:
  - After interrupted or failed runs, Apollo can retain a stale or half-closed app session long enough for the next saved-pairing smoke launch to hit control-channel startup problems.
  - Calling the host cancel endpoint before the next primary launch clears that host-side state while preserving the stored pairing identity.
- Swift handling:
  - `IntegrationHarnessConfiguration.cancelCurrentAppBeforeLaunch` and `SWIFT_MOONLIGHT_TEST_CANCEL_BEFORE_LAUNCH=1` opt into this cleanup step.
  - `SmokeTestReport.preLaunchCancelAttempted` records that the cleanup path ran.
  - Product integrations should still prefer orderly runtime stop plus `MoonlightClient.restartSession(...)` for in-app relaunches.
- Test coverage:
  - unit
  - integration

## Unresolved Areas

- exact app list response differences
- exact launch response differences
- exact control-message differences after session establishment
- whether Apollo-specific warp handling changes client-visible recommended bitrate policy
