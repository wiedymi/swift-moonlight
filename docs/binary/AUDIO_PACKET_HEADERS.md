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
