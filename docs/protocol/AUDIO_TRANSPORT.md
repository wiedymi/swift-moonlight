# Audio Transport Protocol

This document defines audio ingest, decode, and sink submission behavior.

Status:
- required for streaming
- mixed specified and observed behavior
- RTP audio parsing and bounded reorder handling are implemented
- encrypted audio packet handling is implemented
- FEC recovery is not implemented yet

References:
- `refs/moonlight-common-c/src/AudioStream.c`
- `refs/moonlight-common-c/src/Limelight.h`

## Goal

Turn incoming audio packets into stable PCM submitted to an `AudioSink`.

## Responsibilities

The audio transport layer must:
- parse incoming audio packets
- initialize the decoder with negotiated stream format
- decode packets into PCM
- preserve ordering and timing
- surface underruns and configuration changes

## Implemented Swift Types

- `RTPHeader`
- `AudioTransportPacket`
- `AudioPacketParser`
- `SimpleAudioDepacketizer`
- `AudioIngestService`

Current implemented behavior:
- parses the fixed RTP audio header
- only forwards RTP payload type `97` packets into the Opus path
- ignores RTP payload type `127` audio FEC packets because full audio FEC recovery is not implemented yet
- ignores malformed or non-RTP datagrams that arrive on the live audio socket instead of failing the whole session
- preserves baseline ordering and buffers a bounded amount of out-of-order data
- drops stale packets that fall behind the current RTP cursor instead of counting them as forward loss
- converts payload bytes into `EncodedAudioPacket`
- forwards packets into `MediaPipeline`
- exposes missing-packet, reordered-packet, and concealment counters for runtime metrics
- can participate in bounded runtime retry when `SessionRuntime` is configured with reconnect attempts
- the current `OpusDecoder` emits signed 16-bit interleaved PCM buffers sized from the negotiated Opus `samplesPerFrame`
- UDP audio channel startup sends the same host-provided ping payload format as the video channel. For Sunshine/Apollo-style 20-byte ping payloads, bytes `16..<20` carry a monotonically increasing big-endian sequence number.
- if the negotiated audio channel does not provide a ping payload, the channel probe falls back to the legacy ASCII `PING` datagram

Current limitations:
- no FEC block handling
- no full FEC recovery path yet

## Output Contract

The audio decoder outputs:
- `PCMBuffer`

The sink consumes:
- `PCMBuffer`

Rules:
- core logic must not depend on a physical speaker device
- decoder configuration is driven by negotiated stream format, not UI preferences
- the null sink must behave like a real consumer from the session core's perspective
- sink implementations must not assume fixed 5 ms audio buffers; decoded frame length follows the negotiated Opus configuration

## Format Rules

Support in v1:
- the host-negotiated audio mode selected by `StreamConfiguration`

Implementation rules:
- decoder setup must be explicit and observable
- channel count and sample rate mismatches are protocol/configuration errors, not silent conversions inside core logic

## Jitter And Underrun Rules

The audio module must:
- preserve packet order
- surface underrun conditions in metrics
- remain safe under temporary missing packets

Current implementation detail:
- when an audio gap exceeds the bounded reorder window, the depacketizer emits a concealment packet and increments `missingAudioPackets`
- the reorder window is limited to 1...32767 packets, within half of the 16-bit sequence space
- packets that arrive behind the current expected RTP sequence number are treated as stale and discarded

## Headless Test Cases

- initialize decoder from negotiated audio format
- decode valid packet fixture into PCM
- preserve packet ordering
- record underrun metric in null-sink integration tests

Current golden coverage:
- `parsesAndDepacketizesAudioPacket()`
- `depacketizesOutOfOrderAudioPacketWithinReorderWindow()`
- `audioIngestServiceFeedsPipeline()`
- `audioIngestServiceTracksConcealmentPackets()`
- `runtimeSnapshotIncludesReorderAndDiscontinuityCounts()`
