# Video Transport Protocol

This document defines the video ingest and depacketization contract.

Status:
- required for streaming
- strongly observed from references
- bounded RTP reorder buffering is implemented
- FEC metadata tracking and best-effort frame FEC status reporting are implemented
- a clean-room Reed-Solomon video FEC core is implemented and unit-tested
- packet-level Reed-Solomon FEC recovery is wired into live depacketization for recoverable single-block gaps

References:
- `refs/moonlight-common-c/src/VideoDepacketizer.c`
- `refs/moonlight-common-c/src/Limelight.h`

## Goal

Turn incoming network video packets into decoded frames through a stable pipeline:

1. packet ingest
2. packet ordering / loss tracking
3. access-unit reconstruction
4. decode submission
5. Metal rendering

## Responsibilities

The video transport layer must:
- parse packet headers
- track packet and frame order
- detect discontinuities
- reconstruct codec payload in decoder-ready form
- emit access units to the decoder abstraction

## Implemented Swift Types

- `RTPHeader`
- `VideoPacketHeader`
- `VideoTransportPacket`
- `VideoPacketParser`
- `VideoDepacketizerConfiguration`
- `ReedSolomonFEC`
- `VideoFECBlockRecoverer`
- `SimpleVideoDepacketizer`
- `VideoIngestService`

Current implemented packet layout:
- RTP fixed header:
  - packet type
  - sequence number
  - timestamp
  - SSRC
- optional RTP extension header:
  - extension profile
  - extension length in 32-bit words
- Moonlight/Sunshine video header:
  - `streamPacketIndex`
  - `frameIndex`
  - `flags`
  - `extraFlags`
  - `multiFecFlags`
  - `multiFecBlocks`
  - `fecInfo`

Current implemented behavior:
- respects the RTP extension bit and skips any extension payload before parsing the NVIDIA video header
- tolerates bare `NV_VIDEO_PACKET + payload` datagrams when an upstream source provides video packets without the RTP envelope, synthesizing ordering fields from the packet header so ingest can continue
- only treats a packet as RTP video when the header looks like RTP v2, uses no CSRC entries, and the payload type is one of the observed Sunshine/Moonlight values (`0` or `96`), to avoid misclassifying bare Apollo/Sunshine video datagrams whose first byte happens to resemble RTP
- derives FEC shard index, data-shard count, and multi-block FEC indexes from the NVIDIA video header
- supports bounded packet reordering before a frame is completed
- the reorder window is limited to 1...32767 packets, within half of the 16-bit sequence space
- buffers out-of-order packets until the frame start and missing gaps arrive
- drops stale packets that fall behind the next expected RTP sequence number instead of treating them as forward gaps
- supports single-packet and multi-packet frame reconstruction
- strips the first-packet frame header using the configured or detected header size
- ignores parity shards for frame payload assembly while still advancing RTP sequence tracking across them
- only treats `EOF` as end-of-frame on the last FEC block for a frame
- records FEC block status for unrecoverable FEC-described frame gaps
- provides a Moonlight-compatible GF(256) Reed-Solomon core that can recover missing data shards from parity shards in deterministic tests
- preserves the FEC-protected `NV_VIDEO_PACKET + payload` bytes for video packets
- provides a tested FEC block recoverer that reconstructs missing data packets from protected bytes, validates recovered header flags, and can feed recovered packets through `SimpleVideoDepacketizer` in synthetic fixtures
- attempts FEC recovery at the missing RTP sequence boundary before declaring a gap unrecoverable, inserting recovered data packets back into the pending depacketizer queue
- derives the FEC block's base RTP sequence from non-SOF shards too, so a missing first data shard can be recovered before frame assembly starts when enough same-block shards arrive
- allows `SessionRuntime` to send Sunshine/Apollo frame FEC status reports (`0x5502`) before requesting an IDR after discontinuity
- extracts Sunshine/Apollo host processing latency from first-packet frame headers when present
- extracts codec parameter sets from Annex B payloads and caches them across frames for decoder reconfiguration
- forwards completed `EncodedVideoFrame` values into `MediaPipeline`
- lets socket receive and depacketization run ahead of decode/render through bounded ordered asynchronous pipeline submission in runtime-created services
- treats VideoToolbox bad-data decode failures as recoverable, counts them, and lets `SessionRuntime` request a fresh IDR instead of converting transient corruption into an immediate session failure
- exposes missing-packet, reordered-packet, discontinuity, and recoverable decode-failure counters for runtime metrics
- exposes an opt-in bounded video packet header trace for smoke/debug tools when live counters show unexplained gaps
- can participate in bounded runtime retry when `SessionRuntime` is configured with reconnect attempts

Current limitations:
- Reed-Solomon FEC recovery currently covers recoverable packets from the active observed FEC block plus pending same-block shards; multi-block edge cases still need captured Sunshine/Apollo fixtures
- no reference-frame invalidation / RFI recovery path yet
- full host-version-aware long frame-header selection is not implemented yet; the current runtime handles the observed `0x01 -> 8 byte` and `0x81 -> 24 byte` first-packet header variants used by Sunshine/Apollo `7.1.431`

## Output Contract

The depacketizer outputs `EncodedVideoFrame` instances in Annex B or otherwise decoder-ready format as required by the downstream decoder policy.

Rules:
- codec-specific bitstream handling must stay inside the video module
- decoder-facing frames must contain timestamp and keyframe metadata
- parameter sets must be propagated when needed for decoder reconfiguration
- host-provided frame processing latency should be preserved when available so runtime metrics can expose it

## Loss And Discontinuity Rules

The depacketizer must:
- detect gaps in packet sequence
- reject incomplete frames when correctness cannot be guaranteed
- request or wait for keyframe recovery according to host behavior and control capabilities

Current implementation detail:
- runtime-created video services use bounded ordered asynchronous pipeline submission by default; direct `VideoIngestService` construction remains synchronous unless the caller opts in
- runtime video metrics are published on a short interval instead of after every decoded frame, keeping control RTT refresh and media-pipeline snapshots off the hot receive path
- sequence gaps that exceed the configured reorder window record a deterministic discontinuity, reset local frame assembly state, and advance to the nearest available packet
- packets that arrive behind the current expected RTP sequence number are treated as stale and discarded
- forward RTP gaps do not count as reordered packets by themselves; the reorder counter increments when a later-arriving packet fills a hole behind the highest sequence already observed
- when current FEC-block metadata is available, the missing-packet counter records holes inside that block rather than the full distance to a packet from a later frame or block
- after a completed frame, if the next visible later-frame packet is not SOF, FEC-block loss accounting starts from that packet's derived block base instead of the old post-frame RTP sequence
- an RTP sequence jump between completed frames is reported as a discontinuity but does not inflate the missing-packet counter as if every skipped sequence belonged to the active frame
- after a completed frame, a later SOF packet advances the depacketizer immediately even when the RTP gap is smaller than the generic reorder window; skipped post-frame parity is ignored, while skipped frame indexes remain visible as discontinuities
- without FEC-block metadata, the missing-packet counter records the distance from the next expected RTP sequence number to the first pending packet that forces the discontinuity
- `SessionRuntime` now surfaces those discontinuities as session warnings to support recovery handling in app or harness code
- when FEC block metadata is available, `SessionRuntime` now sends a best-effort frame FEC status packet on the generic control channel before keyframe recovery
- when a control channel is available, `SessionRuntime` now also sends an IDR request (`0x0302`) on the urgent control channel after video discontinuity is detected

Observed note:
- sequence and discontinuity handling is a major hidden-behavior area and must be regression tested with fixtures

## Decoder Boundary

The transport layer does not know about Metal.

It emits:
- `EncodedVideoFrame`

The decoder emits:
- `DecodedVideoFrame`

The renderer consumes:
- `DecodedVideoFrame`

## Headless Test Cases

- in-order packet sequence -> one reconstructed frame
- out-of-order packets handled or rejected deterministically
- missing packet causes discontinuity handling
- codec parameter set update causes decoder reconfigure event
- keyframe recovery fixture

Current golden coverage:
- `parsesVideoPacketHeaders()`
- `parsesSunshineHostProcessingLatencyFromVideoHeader()`
- `depacketizesSinglePacketVideoFrame()`
- `depacketizesMultiPacketVideoFrame()`
- `depacketizesOutOfOrderVideoFrameWithinReorderWindow()`
- `rejectsVideoSequenceDiscontinuity()`
- `depacketizerQueuesFrameFECStatusWhenFecFrameBecomesUnrecoverable()`
- `depacketizerRecoversMissingFecDataShardBeforeDiscontinuity()`
- `reedSolomonFECRecoversSingleMissingDataShard()`
- `reedSolomonFECRecoversMultipleMissingDataShards()`
- `videoFECBlockRecovererRecoversMissingMiddlePacket()`
- `videoFECBlockRecovererRejectsCorruptRecoveredHeader()`
- `sessionRuntimeSendsFrameFECStatusOnVideoDiscontinuity()`
- `videoIngestServiceFeedsPipeline()`
- `runtimeSnapshotIncludesReorderAndDiscontinuityCounts()`
