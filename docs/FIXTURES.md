# Fixture Inventory

This document tracks every fixture category required before and during protocol implementation.

## Goals

- make undocumented behavior reproducible
- avoid rediscovering protocol details from references repeatedly
- support deterministic unit and integration tests

## Fixture Classes

### Host HTTP/XML Fixtures

Purpose:
- validate parsing of host metadata and app lists

Required fixtures:
- Sunshine `serverinfo` paired
- Sunshine `serverinfo` unpaired
- Apollo `serverinfo` paired
- Apollo `serverinfo` unpaired
- Sunshine app list
- Apollo app list

Stored form:
- raw response body
- request metadata sidecar when relevant

### Pairing Transcript Fixtures

Purpose:
- validate ordering, parsing, and crypto boundary handling

Required fixtures:
- successful Sunshine pairing transcript
- failed Sunshine pairing transcript with wrong PIN
- successful Apollo pairing transcript
- invalid or out-of-order transcript

Stored form:
- per-step request query parameters
- per-step response body
- redacted sensitive material

Rules:
- never commit private keys or reusable secrets
- redact any material that would allow host impersonation

### Session Negotiation Fixtures

Purpose:
- validate launch and session setup parsing

Required fixtures:
- Sunshine launch accepted
- Sunshine launch rejected
- Apollo launch accepted
- RTSP setup transcript for Sunshine
- RTSP setup transcript for Apollo

Stored form:
- launch request parameter set
- launch response body
- RTSP message sequence transcript

### Input Encoding Fixtures

Purpose:
- lock binary output of the encoder

Required fixtures:
- relative mouse move packet
- absolute mouse move packet
- mouse button packet
- keyboard key down/up packet
- UTF-8 text packet
- touch packet
- controller arrival packet
- Xbox controller state packet
- DualSense controller state packet

Stored form:
- semantic input event JSON
- expected binary output hex
- notes for any host-specific variation

### Video Fixtures

Purpose:
- validate depacketization and discontinuity handling

Required fixtures:
- in-order frame packet sequence
- missing packet sequence
- out-of-order packet sequence
- keyframe recovery sequence
- codec reconfiguration sequence if encountered

Stored form:
- packet metadata sequence
- payload bytes
- expected reconstructed access units

### Audio Fixtures

Purpose:
- validate audio decode and ordering

Required fixtures:
- valid negotiated audio configuration
- short packet sequence
- reordered packet sequence
- underrun scenario

Stored form:
- packet metadata sequence
- payload bytes
- expected PCM metadata

## Storage Layout

Recommended layout:

- `Fixtures/hosts/`
- `Fixtures/pairing/`
- `Fixtures/session/`
- `Fixtures/input/`
- `Fixtures/video/`
- `Fixtures/audio/`

Each fixture set should include:
- raw material
- a short README or manifest
- provenance note

## Provenance Rules

Every fixture must document:
- source host kind
- source version if known
- capture date
- whether it is raw, redacted, or synthesized
- linked note in `docs/OBSERVED_BEHAVIORS.md` when behavior is undocumented

## Native Opus Fixtures

`Tests/SwiftMoonlightTests/Fixtures/opus*` contains synthetic audio created on
2026-10-05 with the former checked-in libopus 1.6.1 build, before its removal.
No live host data is included. Each set has three raw multistream packets and a
little-endian signed 16-bit PCM reference containing their output followed by
one lost-packet recovery block.

Sets cover stereo, 5.1, and 7.1 at 48 kHz, with 960-sample (20 ms) and
240-sample (5 ms, `opus_short_*`) packets. Each input channel is a 10,000-amplitude
sine at `200 + channelIndex * 100` Hz, with continuous phase across the three
packets. The encoder uses `OPUS_APPLICATION_RESTRICTED_LOWDELAY`, default encoder
settings, identity channel mapping, and stream/coupled counts 1/1, 4/2, or 5/3.
Reference decoding uses output mappings `[0, 1]`, `[0, 4, 1, 5, 2, 3]`, or
`[0, 6, 1, 7, 2, 3, 4, 5]`. The last block passes a null input to the reference
decoder, with the same frame length as the preceding packets.

The tests need no external encoder. They allow a maximum difference of 16 signed
PCM units for codec rounding, while checking every output sample and channel.
They also check that a new packet can be decoded after a loss.

### Native video decode fixture

`video_h264_64x64.frame` is one black 64 x 64 H.264 keyframe in Annex-B format,
including SPS and PPS. It was encoded locally with Apple VideoToolbox, with frame
reordering disabled. It contains no captured desktop content. The decoder test
submits it repeatedly with distinct timestamps and verifies real NV12 pixel
buffers and ordered callback completion in Debug and Release.

## ENet fixtures

The pinned SwiftENet package owns the synthetic golden connect bytes, all command
layouts, sequence/time wrap, packet order, retry, fragment, queue/window, and
malformed packet cases. These are synthetic fixtures, not captured private sessions.
`Network/ENetSocketTests.swift` checks Moonlight startup, background retries and
receive, shared adapters, read cancellation, and close against a local UDP peer.
`scripts/enet-checks/run.py` checks the actual old/new transports against an
external ENet C echo host. No C module is required for `swift test`. Reference
sources and build files are removed after each run.
