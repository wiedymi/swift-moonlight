# Binary Packet Layouts

This document is the index for exact binary packet layout documentation.

Purpose:
- make encoder/decoder behavior explicit
- prevent binary protocol details from being buried in implementation code
- support golden tests and fixture reviews

## Rules

- each packet family gets its own document
- field order, width, signedness, endianness, and normalization rules must be stated explicitly
- when a layout is observed rather than publicly specified, link to `docs/OBSERVED_BEHAVIORS.md`
- when host-specific variants exist, document them separately

## Packet Docs

- `docs/binary/MOUSE_PACKETS.md`
- `docs/binary/KEYBOARD_PACKETS.md`
- `docs/binary/TOUCH_PACKETS.md`
- `docs/binary/CONTROLLER_PACKETS.md`
- `docs/binary/VIDEO_PACKET_HEADERS.md`
- `docs/binary/AUDIO_PACKET_HEADERS.md`
- `docs/binary/CONTROL_MESSAGES.md`
- `docs/binary/RTSP_MESSAGES.md`

Current implementation-backed docs:
- `docs/binary/MOUSE_PACKETS.md`
- `docs/binary/KEYBOARD_PACKETS.md`
- `docs/binary/CONTROLLER_PACKETS.md`
- `docs/binary/CONTROL_MESSAGES.md`
- `docs/binary/RTSP_MESSAGES.md`

Related negotiation docs:
- `docs/protocol/CHANNEL_ESTABLISHMENT.md`

## Minimum Per-Doc Contents

- packet family purpose
- packet variants
- exact field table
- normalization/clamping rules
- host compatibility notes
- one or more hex examples
- golden test mapping
