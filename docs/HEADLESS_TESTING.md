# Headless Testing Strategy

This document describes how to test `swift-moonlight` without requiring an interactive UI.

## 1. Principle

Headless testing only works if platform-dependent rendering and playback are behind interfaces.

Everything below the app UI should be testable in one of these forms:
- pure unit test
- fixture-driven protocol test
- local integration test against Sunshine
- network fault-injection test

## 2. Test Layers

### Unit Tests

Purpose:
- verify pure Swift logic with deterministic inputs

Examples:
- XML/HTTP response parsing
- session parameter encoding
- packet header parsing
- input event encoding
- state machine transitions
- retry and timeout behavior

Expected environment:
- `swift test`

### Fixture Tests

Purpose:
- validate undocumented or observed behavior without requiring a live host

Fixtures should include:
- host info responses
- app list responses
- pairing handshake transcripts
- control messages
- input packet examples
- captured video/audio packet sequences where legally safe to store

Expected environment:
- `swift test`

### Integration Tests

Purpose:
- verify real interoperability with Sunshine

Approach:
- launch or connect to a prepared Sunshine host
- run automated pairing
- request app list
- start a session
- send representative input
- verify stream channel establishment and telemetry

Expected environment:
- local developer machine or dedicated CI runner with Sunshine available

### Fault Injection Tests

Purpose:
- verify behavior under packet loss, delay, reorder, disconnects, and invalid responses

Approach:
- wrap transport in a proxy/shim that can:
  - delay packets
  - drop packets
  - reorder packets
  - corrupt packets
  - close channels at defined points

Expected environment:
- local integration test harness

## 3. Required Test Abstractions

To support headless testing, the codebase should avoid direct hard dependencies in core logic on:
- visible windows
- real audio hardware
- real controller hardware
- concrete socket types
- concrete clock implementations

Introduce interfaces for:
- clock / timers
- TCP/UDP transport
- video decoder
- audio sink
- input device source
- persistence layer

Reference test doubles:
- `MockClock`
- `LoopbackTransport`
- `RecordingVideoDecoder`
- `RecordingRenderer`
- `RecordingAudioDecoder`
- `NullAudioSink`
- `FakeInputSource`
- `InMemoryHostStore`

Useful live packet source:
- `UDPPacketSource` for loopback and local socket-fed packet tests

Useful runtime harness layer:
- `SessionRuntime` for pumping control/video/audio services into a session during tests

## 4. Sunshine-Based Headless Harness

The best real integration target is Sunshine because it is the actively maintained host.

Minimum harness capabilities:
- read host URL and credentials from environment
- pair if needed
- fetch server info
- fetch app list
- launch a known app or desktop session
- open control/video/audio/input channels
- send a configured safe input probe through the active input transport
- remain connected for a fixed smoke-test duration
- collect metrics and fail on negotiation errors or unexpected disconnects

Suggested environment variables:
- `SWIFT_MOONLIGHT_TEST_HOST`
- `SWIFT_MOONLIGHT_TEST_PIN`
- `SWIFT_MOONLIGHT_TEST_APP_ID`
- `SWIFT_MOONLIGHT_TEST_CERT_DIR`
- `SWIFT_MOONLIGHT_TEST_STORAGE_DIR`
- `SWIFT_MOONLIGHT_TEST_RESOLUTION`
- `SWIFT_MOONLIGHT_TEST_FPS`
- `SWIFT_MOONLIGHT_TEST_BITRATE_KBPS`
- `SWIFT_MOONLIGHT_TEST_DYNAMIC_RANGE`
- `SWIFT_MOONLIGHT_TEST_CODEC`
- `SWIFT_MOONLIGHT_TEST_CODECS`
- `SWIFT_MOONLIGHT_TEST_CONTINUOUS_AUDIO`
- `SWIFT_MOONLIGHT_TEST_REQUIRE_AUDIO`
- `SWIFT_MOONLIGHT_TEST_INPUT_PROBE`
- `SWIFT_MOONLIGHT_TEST_INPUT_PROBE_REPEAT_COUNT`
- `SWIFT_MOONLIGHT_TEST_MAX_INPUT_LATENCY_MS`
- `SWIFT_MOONLIGHT_TEST_MAX_MISSING_VIDEO_PACKETS`
- `SWIFT_MOONLIGHT_TEST_MAX_VIDEO_DISCONTINUITIES`
- `SWIFT_MOONLIGHT_TEST_VIDEO_PACKET_TRACE_LIMIT`
- `SWIFT_MOONLIGHT_TEST_CANCEL_BEFORE_LAUNCH`
- `SWIFT_MOONLIGHT_TEST_RESTART_RESOLUTION`
- `SWIFT_MOONLIGHT_TEST_RESTART_COUNT`
- `SWIFT_MOONLIGHT_TEST_OBSERVATION_SECONDS`
- `SWIFT_MOONLIGHT_TEST_REPORT_JSON`
- `SWIFT_MOONLIGHT_CAPTURE_OUTPUT_DIR`
- `SWIFT_MOONLIGHT_CAPTURE_FRAME_LIMIT`
- `SWIFT_MOONLIGHT_CAPTURE_TIMEOUT_SECONDS`
- `SWIFT_MOONLIGHT_CAPTURE_RESOLUTION`
- `SWIFT_MOONLIGHT_CAPTURE_FPS`
- `SWIFT_MOONLIGHT_CAPTURE_BITRATE_KBPS`
- `SWIFT_MOONLIGHT_CAPTURE_DYNAMIC_RANGE`
- `SWIFT_MOONLIGHT_CAPTURE_CODEC`
- `SWIFT_MOONLIGHT_CAPTURE_CODECS`
- `SWIFT_MOONLIGHT_CAPTURE_CANCEL_BEFORE_LAUNCH`
- `SWIFT_MOONLIGHT_CAPTURE_REQUIRE_HDR`
- `SWIFT_MOONLIGHT_CAPTURE_REQUIRE_AUDIO`
- `SWIFT_MOONLIGHT_CAPTURE_CONTINUOUS_AUDIO`
- `SWIFT_MOONLIGHT_CAPTURE_INPUT_VISUAL_PROBE`
- `SWIFT_MOONLIGHT_CAPTURE_REQUIRE_INPUT_VISUAL_PROBE`
- `SWIFT_MOONLIGHT_CAPTURE_INPUT_VISUAL_MIN_CHANGED_PIXEL_RATIO`
- `SWIFT_MOONLIGHT_CAPTURE_REQUIRE_INPUT_VISUAL_EXPECTED_REGIONS`
- `SWIFT_MOONLIGHT_CAPTURE_INPUT_VISUAL_EXPECTED_REGION_MIN_CHANGED_PIXEL_RATIO`
- `SWIFT_MOONLIGHT_CAPTURE_INPUT_VISUAL_TARGET_URL`
- `SWIFT_MOONLIGHT_CAPTURE_INPUT_VISUAL_EXPECTED_FRAME`
- `SWIFT_MOONLIGHT_CAPTURE_MAX_MISSING_VIDEO_PACKETS`
- `SWIFT_MOONLIGHT_CAPTURE_MAX_VIDEO_DISCONTINUITIES`
- `SWIFT_MOONLIGHT_CAPTURE_MAX_RECOVERABLE_VIDEO_DECODE_FAILURES`
- `SWIFT_MOONLIGHT_CAPTURE_REPORT_JSON`

Current implementation note:
- `IntegrationHarnessConfiguration.fromEnvironment(...)` supports `SWIFT_MOONLIGHT_TEST_HOST` as either `host`, `host:port`, or URL form
- `swift-moonlight-smoke` prefers a paired exact host match, and when the configured host override points at a stale or unpaired duplicate while exactly one paired host is stored, it adopts the override endpoint for that paired host before refreshing
- `swift-moonlight-smoke` resolves `SWIFT_MOONLIGHT_TEST_APP_ID=desktop` against either a literal `desktop` app ID or an app named `Desktop`, matching Apollo app lists that expose Desktop under a numeric ID
- `IntegrationHarnessConfiguration.fromEnvironment(...)` enables `SWIFT_MOONLIGHT_TEST_CONTINUOUS_AUDIO` by default, but does not fail a smoke run on zero audio packets unless `SWIFT_MOONLIGHT_TEST_REQUIRE_AUDIO=1`
- `SWIFT_MOONLIGHT_TEST_RESOLUTION=1280x720`, `SWIFT_MOONLIGHT_TEST_FPS=30`, `SWIFT_MOONLIGHT_TEST_BITRATE_KBPS=8000`, `SWIFT_MOONLIGHT_TEST_DYNAMIC_RANGE=sdr|hdr`, `SWIFT_MOONLIGHT_TEST_CODEC=h264`, and `SWIFT_MOONLIGHT_TEST_CODECS=hevc,h264` override the primary smoke stream request
- `SWIFT_MOONLIGHT_TEST_INPUT_PROBE` supports `noop` (default), `motion` for reversible `+1/-1` relative mouse movement, `absolute` for a no-click absolute pointer sweep, and `disabled`
- `SWIFT_MOONLIGHT_TEST_INPUT_PROBE_REPEAT_COUNT=50` repeats the safe input probe before observation, giving local queue/transport latency soak evidence without clicks or text input
- `SWIFT_MOONLIGHT_TEST_MAX_INPUT_LATENCY_MS=20` makes the smoke report fail when max local input queue latency or max input transport-send latency exceeds the threshold
- `SWIFT_MOONLIGHT_TEST_MAX_MISSING_VIDEO_PACKETS=0` makes the smoke report fail when a primary or restart observation reports more missing video packets than the threshold
- `SWIFT_MOONLIGHT_TEST_MAX_VIDEO_DISCONTINUITIES=0` makes the smoke report fail when a primary or restart observation reports more video discontinuities than the threshold
- `SWIFT_MOONLIGHT_TEST_VIDEO_PACKET_TRACE_LIMIT=32` includes a bounded ring of parsed video packet headers in the smoke report for diagnosing live missing-packet/discontinuity counters
- `SWIFT_MOONLIGHT_TEST_CANCEL_BEFORE_LAUNCH=1` asks the host to cancel the currently running app before opening the primary smoke session, useful when saved-pairing smoke runs are repeated against a stale or half-closed host session
- `SWIFT_MOONLIGHT_TEST_OBSERVATION_SECONDS=2.5` overrides the per-session observation window; use short values for local checks and larger values for soak runs
- `SWIFT_MOONLIGHT_TEST_REPORT_JSON=/tmp/smoke.json` writes a pretty-printed machine-readable report containing the smoke result, derived `passed` flag, and failure list
- `IntegrationHarness.production(...)` builds a production client plus harness directly from the environment-backed configuration
- `SWIFT_MOONLIGHT_TEST_RESTART_RESOLUTION=1600x900` makes `IntegrationHarness.runSmokeTest()` observe the first session, restart through `MoonlightClient.restartSession(...)` at the requested resolution, and report second-session channel and packet counters
- `SWIFT_MOONLIGHT_TEST_RESTART_COUNT=3` repeats that restart path three times, preserving one active runtime at a time and recording per-restart observations for resize/relaunch soak checks
- `IntegrationHarness.runSmokeTest()` sends the configured input probe after the runtime starts and reports `inputProbeSucceeded`, `inputProbeMode`, plus `inputPacketsSent`
- smoke reports include `controlRoundTripTimeMs`, `controlRoundTripTimeVarianceMs`, `controlPacketLossRatio`, and `controlPacketLossVarianceRatio` when the live control transport can expose ENet telemetry
- smoke reports include `videoFrameFECStatusReports` so live runs can prove the advertised FEC-status compatibility path was exercised during discontinuity recovery
- capture reports include `recoverableVideoDecodeFailures` so packet-loss-induced VideoToolbox bad-data recovery is visible without treating every decoder rejection as a fatal smoke failure
- `swift-moonlight-capture` reuses persisted production storage, attaches `VideoToolboxDecoder`, and writes decoded pixel buffers to PNG files for end-to-end headless verification
- if `SWIFT_MOONLIGHT_TEST_HOST` is provided to `swift-moonlight-capture`, the capture tool prefers a paired exact host match. If the override points at a stale or unpaired duplicate and exactly one paired host is stored, it adopts that endpoint for the paired host. This lets saved paired credentials survive a stale `.local` name when the user supplies a raw IP address.
- `swift-moonlight-capture` can request capture-specific stream settings with `SWIFT_MOONLIGHT_CAPTURE_RESOLUTION=1920x1080`, `SWIFT_MOONLIGHT_CAPTURE_FPS=60`, `SWIFT_MOONLIGHT_CAPTURE_BITRATE_KBPS=20000`, `SWIFT_MOONLIGHT_CAPTURE_DYNAMIC_RANGE=sdr|hdr`, and `SWIFT_MOONLIGHT_CAPTURE_CODECS=hevc,h264`
- `SWIFT_MOONLIGHT_CAPTURE_CANCEL_BEFORE_LAUNCH=1` asks the host to cancel the currently running app before opening capture, matching the smoke tool's repeated saved-pairing workflow.
- `SWIFT_MOONLIGHT_CAPTURE_REQUIRE_HDR=1` makes capture fail unless at least one decoded frame carries PQ, HLG, or ITU-R 2100 transfer metadata
- `SWIFT_MOONLIGHT_CAPTURE_REQUIRE_AUDIO=1` makes capture fail when the audio channel observes no packets
- when audio is required, `swift-moonlight-capture` keeps the session open until both the requested frame count and at least one audio packet are observed, or until the capture timeout expires
- `swift-moonlight-capture` enables continuous audio by default and disables it only when `SWIFT_MOONLIGHT_CAPTURE_CONTINUOUS_AUDIO=0`
- `SWIFT_MOONLIGHT_CAPTURE_INPUT_VISUAL_PROBE=relative` makes capture wait for a baseline frame, send reversible relative mouse motion, and compare pre/post decoded PNGs. `absolute` sends a no-click absolute move to 25% width, captures that as the comparison baseline, sends a second move to 75% width, then recenters the pointer afterward.
- input visual probes report input packet counts plus mean, RMS, max, changed-pixel image deltas, changed-pixel bounds, and for absolute probes, changed-pixel ratios in the expected source/destination cursor regions. Bounds are diagnostic only: dynamic desktop content can make the changed region span the full frame, so this remains a visual heuristic rather than exact cursor localization.
- `SWIFT_MOONLIGHT_CAPTURE_REQUIRE_INPUT_VISUAL_PROBE=1` makes the run fail if the visual probe cannot observe a decoded-frame change. Keep this opt-in because cursor visibility, host desktop animation, and changing app content make this a heuristic rather than proof of exact cursor synchronization.
- `SWIFT_MOONLIGHT_CAPTURE_INPUT_VISUAL_MIN_CHANGED_PIXEL_RATIO` tunes the changed-pixel threshold for that heuristic. The default is `0.00005`, with per-pixel channel deltas counted when at least one RGB channel changes by 12 or more.
- `SWIFT_MOONLIGHT_CAPTURE_REQUIRE_INPUT_VISUAL_EXPECTED_REGIONS=1` makes absolute probes fail unless both expected source/destination cursor regions meet `SWIFT_MOONLIGHT_CAPTURE_INPUT_VISUAL_EXPECTED_REGION_MIN_CHANGED_PIXEL_RATIO`; the default expected-region threshold is `0.001`.
- for stricter input validation, serve `docs/input-visual-target.html` with `scripts/serve-input-visual-target.sh`, open it full-screen on the streamed host, then run capture with `SWIFT_MOONLIGHT_CAPTURE_INPUT_VISUAL_PROBE=absolute` and `SWIFT_MOONLIGHT_CAPTURE_REQUIRE_INPUT_VISUAL_EXPECTED_REGIONS=1`. The helper server runs until Ctrl-C by default; pass a second argument such as `120` to auto-stop after that many seconds.
- `SWIFT_MOONLIGHT_CAPTURE_INPUT_VISUAL_TARGET_URL=http://<mac-ip>:8765/input-visual-target.html` lets capture try to open the visual target on a Windows/Apollo desktop through Win+R plus chunked text input before running the probe. When this target is configured, the absolute probe also clicks the target points so browsers that ignore passive synthetic moves before activation still emit pointer events. This is a convenience for saved-paired local smoke runs, not a cross-platform browser automation guarantee.
- `SWIFT_MOONLIGHT_CAPTURE_INPUT_VISUAL_OPEN_HELPER_URL=http://<mac-ip>:8765/open-input-visual-target.ps1` tries to open the target through a PowerShell helper instead of launching the URL directly. This is experimental and exists for Apollo virtual-display desktops where Windows may otherwise open the browser on a non-streamed monitor. For the shortest Windows Run command, use `SWIFT_MOONLIGHT_CAPTURE_INPUT_VISUAL_TARGET_URL=http://<mac-ip>:8765/t.html`.
- `SWIFT_MOONLIGHT_CAPTURE_INPUT_VISUAL_EXPECTED_FRAME=x,y,width,height` scopes expected-region checks to a visible target rectangle using normalized stream coordinates. The default is `0,0,1,1`; use `0,0,0.5,1` when the target browser window fills the left half of the streamed desktop.
- the visual target page renders a high-contrast sentinel in the top-left corner plus its own high-contrast marker from host `pointermove`/`mousemove` events. When `SWIFT_MOONLIGHT_CAPTURE_INPUT_VISUAL_TARGET_URL` is set, capture requires the sentinel to be visible before accepting the visual probe, so wallpaper changes or unrelated desktop animation cannot pass as target input proof.
- `docs/open-input-visual-target.ps1` is an optional host-side helper for Apollo/Windows diagnostics. If a browser opens on a non-streamed monitor, serve this file from the same temporary helper server and run it on the host to open Edge on the monitor nearest the streamed cursor.
- `SWIFT_MOONLIGHT_CAPTURE_MAX_MISSING_VIDEO_PACKETS`, `SWIFT_MOONLIGHT_CAPTURE_MAX_VIDEO_DISCONTINUITIES`, and `SWIFT_MOONLIGHT_CAPTURE_MAX_RECOVERABLE_VIDEO_DECODE_FAILURES` make capture fail when stream recovery counters exceed integration-specific quality limits
- `SWIFT_MOONLIGHT_CAPTURE_REPORT_JSON=/tmp/capture.json` writes a pretty-printed machine-readable capture report with image paths, audio/WAV evidence, probe deltas, metrics, warnings, and failures
- capture reports include host-reported `hdrMode` state so HDR-required runs can distinguish a true renderer/color problem from a host or display that accepted an HDR launch request but reported HDR disabled
- Apollo reference sources currently do not handle the Sunshine `continuousAudio` launch flag, so Apollo audio-required capture runs still need a deterministic host-side audio source to produce packets.

## 5. Video Testing Without a Window

Do not make display output the first test target.

Instead:
- test packet parsing and NAL/sample reconstruction first
- validate decoder submission boundaries
- use a fake decoder that records submitted access units and yields deterministic `DecodedVideoFrame` values
- keep Metal behind a render interface so tests can swap in a no-op renderer
- optionally use `VTDecompressionSession` only in specialized integration tests

What to assert:
- SPS/PPS/VPS handling
- IDR boundaries
- frame ordering
- timestamp propagation
- behavior under loss or missing keyframes

Current implementation note:
- `swift-moonlight-capture` is the current end-to-end image verifier for macOS. It opens a real session, waits for decoded frames, and fails if no PNG files are written.
- `swift-moonlight-capture` writes `frame-metadata.json` next to captured PNG files with pixel format, plane layout, and CoreVideo color/HDR attachments for SDR/HDR debugging.
- Metal PNG readback uses the same range/matrix-aware bi-planar shader path as the app surface, including the conservative PQ-to-SDR tone map and BT.2020-to-BT.709 fallback, so captured PNGs can be used to compare the displayed color path instead of a separate CoreGraphics conversion.
- `swift-moonlight-capture` reports Metal-readback mean, RMS, and max RGB deltas against the decoded PNG path. SDR-metadata captures fail when that delta is large enough to indicate a broken Metal color path.
- The smoke and capture tools report `inputEventsSent`/`inputPacketsSent` plus average/max input queue and transport latencies so headless runs can catch sender-side regressions without opening the test app.
- `swift-moonlight-capture` also attaches the production Opus decoder and writes decoded PCM to `audio.wav`, so paired-host smoke runs can verify that audio packets decrypt and decode without requiring speakers.

## 6. Audio Testing Without Speakers

Use a null sink.

Pipeline:
- ingest packets
- decode to PCM
- send to `AudioSink`
- in tests, the sink stores buffer metadata and payload for assertions

What to assert:
- sample rate and channel config
- packet-to-PCM continuity
- underrun handling
- jitter buffering behavior

## 7. Input Testing Without Devices

Input should be encoded from semantic events, not directly from platform APIs.

Test strategy:
- construct semantic events in tests
- encode wire packets
- compare against approved binary fixtures or expected field values

Examples:
- touch begin/move/end
- mouse absolute/relative move
- left/right click
- keyboard press/release
- virtual controller button/axis changes

## 8. Observability Requirements

Every integration test must be able to assert on logs or metrics instead of UI.

Minimum structured outputs:
- state transitions
- negotiated codecs and resolutions
- pairing result
- disconnect reason
- packet counters
- decode submit counters
- render submit counters
- audio packet counters
- input packet counters

Current implementation note:
- `session.metrics` now carries both session-local counters and runtime-observation counters, so most headless tests can assert through the session surface without separately polling `SessionRuntime.snapshot()`
- `session.metrics` now also carries session-open timing, media decode latency, and audio underrun metrics from the media pipeline
- `session.metrics` reports video pipeline queue time and render submission time; these are local timing stages, not input-to-display latency
- `session.metrics` now also carries host-provided video processing latency metrics from Sunshine/Apollo frame headers when present
- `session.metrics` now also carries transport missing/reorder/discontinuity counters from the media ingest layer
- `session.metrics` now also carries bounded runtime reconnect-attempt counts from `SessionRuntime`
- when a client is created with a configured `MetricsSink`, `openSession(...)` forwards that same session metric stream into the sink for external collection
- `session.events` now also carries a warning when video discontinuity is detected, so recovery-sensitive tests can assert on the event stream instead of only polling counters

## 9. CI Strategy

Recommended split:

- fast CI
  - unit tests
  - fixture tests
  - state machine tests

- gated integration CI
  - Sunshine interoperability tests
  - packet fault-injection tests

- manual or dedicated-runner tests
  - hardware decode validation
  - long-duration soak tests

Do not block all development on GPU-backed decode in general CI.

## 10. First Headless Milestones

1. Pairing transcript tests against recorded host responses
2. App list parsing tests
3. Input packet encoder golden tests
4. Session state machine tests
5. Session runtime tests with fixture or loopback packet sources
5. Sunshine smoke test with null video/audio sinks
6. Video depacketizer fixture tests
7. Audio decode fixture tests
