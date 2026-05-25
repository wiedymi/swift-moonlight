# Parity Roadmap

This file tracks the gap between the current Swift implementation and a production-ready Moonlight-compatible Apple SDK.

Status values:
- `working`: implemented and verified by unit/fixture/live evidence
- `partial`: implemented enough for a happy path, but missing edge cases or coverage
- `missing`: not implemented in a usable form
- `blocked`: needs captured behavior, external dependency, or product decision

## Production Integration Gate

The library is ready for real app integration when these gates are satisfied:

- stable public API surface with documented lifecycle ownership
- deterministic configuration validation before host side effects
- repeatable Sunshine and Apollo smoke tests that pass without the test app UI
- reliable Metal presentation for SDR streams
- correct HDR presentation or explicit HDR opt-out
- audio decode/playback without noise, drift, or speaker-only test dependency
- direct and captured mouse input match host cursor behavior on Sunshine and Apollo
- keyboard input covers common macOS layouts and repeat behavior
- physical controller support covers Xbox and DualSense baseline input
- session stop, host cancel, and app teardown are deterministic
- runtime errors map to actionable typed failures
- app credentials and pairing identity can be stored in app-appropriate secure storage

## Current Matrix

| Area | Status | Evidence | Missing Before Production |
| --- | --- | --- | --- |
| SwiftPM package shape | working | `Package.swift`, app/test/smoke/capture targets | semantic versioning and release process |
| Public client API | partial | `MoonlightClient`, `ProductionClientFactory`, docs/api | lifecycle examples for app foreground/background, API stability review |
| Stream configuration | working | `StreamConfiguration.validate()`, host-capability validation after server info, core/client tests | broader preset policy for host-specific modes |
| Host discovery | partial | Bonjour discovery, manual hosts, endpoint deduplication | wider network discovery soak |
| Host persistence | partial | `FileHostStore`, `FileIdentityStore`, `KeychainIdentityStore`, `KeychainRSAPairingIdentityStore` | migration path from legacy file credentials and app-level backup/restore policy |
| Pairing | partial | Sunshine/Apollo pairing paths, OTP query support, fixtures | live pair/unpair matrix for clean Sunshine and Apollo installs |
| App list | partial | Sunshine/Apollo XML fixtures, per-app HDR flag parsing, and live use | Apollo permission-denied app visibility tests |
| Launch query | partial | Sunshine and Apollo launch-query tests, Apollo production defaults request virtual display mode | more Apollo display-mode override policy coverage |
| RTSP negotiation | partial | live TCP RTSP and encrypted `rtspenc://` support | richer Apollo RTSP extension fixtures |
| Channel establishment | partial | UDP sockets, ENet control transport, runtime factory | long-duration channel lifecycle and teardown soak |
| Control stream | partial | live HDR control message observed, IDR request support, Moonlight-shaped periodic ENet ping, RTT/loss metrics | fuller Moonlight C control message parity and latency-driven adaptation |
| Video transport | partial | RTP/bare packet parsing, FEC metadata handling tests, clean-room Reed-Solomon FEC core tests, depacketizer Reed-Solomon recovery trigger, synthetic FEC block packet recovery tests, best-effort frame FEC status reports on unrecoverable gaps, bounded async runtime pipeline submission so packet receive is not blocked by decode/render | captured Sunshine/Apollo multi-block FEC fixtures, full Moonlight-shaped frame/FEC queue, and host-version-aware edge cases |
| Video decode | partial | VideoToolbox H.264/HEVC path, explicit AV1 hardware rejection instead of silent frame starvation, fallback promotion on primary configure/decode failure, decode-mode-aware Apple component wiring, uncompressed NV12/P010 output requests, recoverable VideoToolbox bad-data IDR recovery, live PNG capture | AV1 decode, real software decoder fallback |
| Metal rendering | partial | SDR bi-planar compressed surfaces render, uncompressed 10-bit P010 render path, range/matrix-aware YCbCr shader, metadata-gated BT.2020 PQ/HLG-to-SDR fallback, explicit stretch/fit/fill presentation policy and matching pointer geometry helper, opt-in and display-capability-gated automatic `rgba16Float` extended-linear EDR layer modes, Metal tests | measured true-HDR display validation, frame pacing, app-level examples for aspect-preserving surfaces |
| Audio transport | partial | RTP Opus ingest, malformed packet tolerance | audio FEC recovery and more jitter/underrun soak |
| Audio decode/sink | partial | Opus decoder, AVAudioEngine sink, and WAV capture path | deterministic live audio-source capture, AV sync, long-running drift tests |
| Direct mouse input | partial | coalescing/splitting/immediate-delivery tests, reusable ordered input dispatch queue, serial test-app input ingress, session-level input flush, full-surface mapping, Sunshine/Apollo host-side coordinate oracle tests, configurable smoke input soak with relative and absolute pointer probes plus local latency thresholds | deterministic live host cursor validation for Sunshine/Apollo; current Apollo virtual-desktop run shows absolute packets can land outside the visual target due display offset |
| Captured mouse input | partial | relative input encoding, immediate mouse delivery option, app capture mode, captured mouse as test-app default for physical mouse input, fractional macOS delta accumulation, reusable ordered input dispatch queue, serial test-app input ingress, lossless relative coalescing, stop-time pending-input flush, opt-in capture visual probe with relative and absolute pointer modes plus input packet/image-delta reporting, capture-side Windows/Apollo visual-target URL opener, pointer-reactive visual target page with sentinel validation for expected-region checks, saved-paired Apollo target-opening capture with healthy audio/video and low local input latency | lock/unlock lifecycle tests, exact Sunshine/Apollo host cursor sync validation with the visual target, and live target-region pass; current Apollo visual-target runs show packets advancing, a stricter sentinel run showed the host fetched the page but the browser was not visible on the streamed virtual display, and the experimental PowerShell helper has not yet executed reliably through Win+R |
| Keyboard input | partial | Win32 virtual-key mapping tests; headless test-app surface state tests suppress AppKit key repeats, release tracked keys/buttons/modifiers on focus/window teardown, and derive left/right modifier transitions from side-specific AppKit flags | layout/IME coverage and live keyboard-repeat validation |
| Touch/pen input | partial | encoders, packet tests, host-independent normalized coordinate tests, Sunshine/Apollo host-side coordinate oracle tests | real Sunshine/Apollo touch/pen host validation fixtures |
| Physical controllers | partial | GameController boundary, packet models, Xbox/DualSense profile mapping, battery/motion/touchpad source events, typed host feedback events, built-in GameController feedback sink for handle rumble/trigger rumble/LED/motion activation | Xbox/DualSense live tests and full DualSense adaptive-trigger payload mapping |
| HDR | partial | metadata parsing/logging, typed HDR mode session events, control packet parsing, structured capture `hdrMode` reporting, uncompressed P010 decode request, BT.2020-aware conservative PQ/HLG-to-SDR Metal fallback, opt-in and automatic EDR Metal layer configuration, live Apollo HDR-required capture with mixed SDR-startup and PQ/BT.2020 frames | measured HDR/EDR display validation and dynamic screen-change handling |
| Dynamic resize | partial | launch-time `Window` preset, test-app debounced resize relaunch through public `restartSession(...)` helper, headless smoke restart at a second resolution with live Apollo packet evidence, configurable multi-restart smoke soak, saved-paired Apollo 3-restart 1600x900 audio-required smoke with zero missing video packets and zero discontinuities | no mid-stream renegotiation yet; longer-running app integration soak and host display-mode evidence |
| Reconnect | partial | bounded runtime retry | full session resume/relaunch recovery |
| Headless testing | partial | smoke and capture executables, configurable safe relative/absolute input probes, input latency thresholds, smoke/capture stream-quality gates, opt-in smoke video packet traces, machine-readable smoke/capture JSON artifacts, multi-restart smoke soak reports, capture frame metadata sidecar, Metal readback delta checks | automated Sunshine/Apollo CI runner and stable fixture corpus |

## Next High-Impact Work

1. Validate the opt-in HDR/EDR presentation path against real display capability, captured `CVPixelBuffer` attachments, and Apollo/Sunshine host color output.
2. Replace the capture visual probe heuristic with deterministic host cursor/touch validation against Sunshine and Apollo.
3. Extend resize/restart soak duration against Apollo virtual display sessions and capture host display-mode evidence.
4. Expand physical controller live smoke coverage for Xbox and DualSense.
5. Add audio-required live smoke coverage with a deterministic host-side audio source, especially for Apollo where the checked-in reference does not honor `continuousAudio`.
