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
