# Video Packet Headers

Status:
- implemented for the current ingest path

Reference source:
- `refs/moonlight-common-c/src/Video.h`
- `refs/moonlight-common-c/src/VideoStream.c`

## Plain Packet Layout

Plain video packets are:
- a 12-byte RTP header
- a 16-byte `NV_VIDEO_PACKET` header
- encoded video payload bytes

### RTP Header

Offset | Size | Endianness | Field
--- | --- | --- | ---
`0` | `1` | n/a | RTP flags/version byte
`1` | `1` | n/a | RTP packet type
`2` | `2` | big-endian | RTP sequence number
`4` | `4` | big-endian | RTP timestamp
`8` | `4` | big-endian | RTP SSRC

### NV Video Header

Offset | Size | Endianness | Field
--- | --- | --- | ---
`12` | `4` | little-endian | `streamPacketIndex`
`16` | `4` | little-endian | `frameIndex`
`20` | `1` | n/a | `flags`
`21` | `1` | n/a | `extraFlags`
`22` | `1` | n/a | `multiFecFlags`
`23` | `1` | n/a | `multiFecBlocks`
`24` | `4` | little-endian | `fecInfo`

Payload starts at offset `28`.

## Flag Bits

`flags`:
- `0x01`: contains picture data
- `0x02`: end of frame
- `0x04`: start of frame

`extraFlags`:
- `0x01`: LTR frame

`fecInfo`:
- bits `31...22`: data shard count
- bits `21...12`: FEC shard index
- bits `11...4`: FEC percentage

`multiFecBlocks`:
- bits `5...4`: current FEC block index
- bits `7...6`: last FEC block index

Video FEC note:
- the clean-room `ReedSolomonFEC` core implements the observed Moonlight-compatible GF(256) parity matrix for data-shard recovery
- `VideoPacketParser` preserves the protected `NV_VIDEO_PACKET + payload` bytes needed for FEC recovery
- `VideoFECBlockRecoverer` can reconstruct and sanity-check missing data packets in synthetic FEC blocks
- `SimpleVideoDepacketizer` attempts recovery at the missing sequence-gap boundary using the active observed FEC block and pending same-block shards before falling back to FEC-status reporting and IDR recovery

## Encrypted Packet Layout

When video encryption is enabled, the UDP datagram no longer begins with an RTP
header. It begins with `ENC_VIDEO_HEADER`, and the remaining bytes are AES-GCM
ciphertext for the full plaintext video packet.

### Encrypted Video Header

Offset | Size | Endianness | Field
--- | --- | --- | ---
`0` | `12` | n/a | AES-GCM IV
`12` | `4` | little-endian | `frameNumber`
`16` | `16` | n/a | AES-GCM tag
`32` | `N` | n/a | ciphertext for plain RTP + NV video header + payload

Notes:
- the 32-byte encrypted header matches `ENC_VIDEO_HEADER` in the reference C code
- `frameNumber` can be inspected before decryption for discard decisions, but it
  is not trusted until authentication succeeds

## Decoder Boundary

The current Swift implementation decrypts encrypted video datagrams back into
the plain packet shape:
- 12-byte RTP header
- 16-byte NV video header
- encoded payload

The normal `VideoPacketParser` then runs on the decrypted bytes.
