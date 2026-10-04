# Audio Packet Headers

Status:
- implemented for the current ingest path

Reference source:
- `refs/moonlight-common-c/src/AudioStream.c`
- `refs/moonlight-common-c/src/Video.h`

## Plain Packet Layout

Audio packets use a plain RTP header followed by the Opus payload.

Offset | Size | Endianness | Field
--- | --- | --- | ---
`0` | `1` | n/a | RTP flags/version byte
`1` | `1` | n/a | RTP packet type
`2` | `2` | big-endian | RTP sequence number
`4` | `4` | big-endian | RTP timestamp
`8` | `4` | big-endian | RTP SSRC
`12` | `N` | n/a | Opus payload

## Encrypted Packet Layout

When audio encryption is enabled, the RTP header stays in plaintext and only the
payload after the 12-byte RTP header is encrypted.

Offset | Size | Endianness | Field
--- | --- | --- | ---
`0` | `12` | mixed RTP fields | RTP header
`12` | `N` | n/a | AES-CBC encrypted Opus payload with PKCS#7 padding

## Audio IV Derivation

Moonlight derives the AES-CBC IV from `avRiKeyID + sequenceNumber` using the
same behavior as `moonlight-common-c`.

Rules:
- `avRiKeyID` is a 32-bit value derived from the remote input IV material
- add the RTP sequence number as an unsigned integer
- encode the sum as big-endian
- place those 4 bytes in the first 4 bytes of a 16-byte IV
- zero the remaining 12 bytes

Example:
- `avRiKeyID = 0x10203040`
- `sequenceNumber = 0x0014`
- derived prefix = `0x10203054`
- IV = `10 20 30 54 00 00 00 00 00 00 00 00 00 00 00 00`

## Decoder Boundary

The current Swift implementation decrypts to:
- original 12-byte RTP header
- original plaintext Opus payload

`AudioPacketParser` then parses the RTP fields and hands the payload to the
audio depacketizer and decoder.

## Native Decoder Setup

Apple AudioToolbox receives the raw decrypted Opus payload, without RTP bytes or
an Ogg container. An OpusHead magic cookie uses the layout in
[RFC 7845 section 5.1](https://www.rfc-editor.org/rfc/rfc7845#section-5.1):
version 1, negotiated channel count, zero pre-skip, little-endian input sample
rate, zero gain, mapping family 1, stream count, coupled stream count, and the
negotiated channel mapping. Zero `AudioConverterPrimeInfo` prevents initial
sample trimming. Tests verify that custom Moonlight surround mappings are
preserved in PCM output.

The first stream's TOC gives packet duration, as specified by
[RFC 6716 section 3](https://www.rfc-editor.org/rfc/rfc6716#section-3). Frame count
must be positive and no greater than 120 ms. A zero-byte packet description with
a valid frame count requests native lost-packet recovery. These AudioToolbox
behaviors are verified by the checked-in synthetic packet and PCM fixtures.
