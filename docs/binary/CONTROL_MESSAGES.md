# Control Messages

Status:
- partially implemented
- incoming control-message parsing is implemented for Sunshine/Apollo-style encrypted control streams
- encrypted control-packet encode/decode is implemented
- live socket-backed control transport is implemented through `UDPControlChannelTransport` and `ENetControlChannelTransport`

References:
- `refs/moonlight-common-c/src/ControlStream.c`
- `refs/moonlight-common-c/src/Limelight.h`
- `refs/moonlight-common-c/src/Limelight-internal.h`
- `refs/apollo/src/stream.cpp`

Implemented Swift types:
- `ControlPacketType`
- `ControlMessage`
- `ControlMessageParser`
- `ControlPacketEncoder`
- `ControlPacketCrypto`
- `ControlChannelService`

Current framing:
- decrypted parser input uses the V1 packet shape:
  - `u16 type` in little-endian
  - payload bytes
- encrypted wire input uses:
  - `u16 encryptedHeaderType` little-endian, always `0x0001`
  - `u16 length` little-endian
  - `u32 seq` little-endian
  - `u8[16] tag`
  - ciphertext of the inner V2 packet
- inner encrypted plaintext uses the V2 shape:
  - `u16 type` little-endian
  - `u16 payloadLength` little-endian
  - payload bytes
- Swift decrypts the V2 plaintext and converts it back to the V1 parser shape by dropping the inner length field

## Encrypted Envelope

Implemented in `ControlPacketCrypto`.

Outer encrypted header fields:
- `encryptedHeaderType`
- `length`
- `seq`

`length` rules:
- value is `sizeof(seq) + tagLength + sizeof(innerV2Header) + payloadLength`
- on the wire this excludes the first 4 bytes of the outer header, matching `ControlStream.c`

Tag placement:
- the 16-byte AES-GCM tag is placed immediately after the outer encrypted header
- ciphertext follows the tag

## Nonce Derivation

Implemented behavior matches the `encryptControlMessage()` and `decryptControlMessageToV1()` logic in `ControlStream.c`.

### V2 control encryption

- nonce length: 12 bytes
- bytes `0...3`: sequence number in little-endian byte order
- byte `10`:
  - `'C'` for client-originated packets
  - `'H'` for host-originated packets
- byte `11`: `'C'` for control stream

### Legacy control encryption

- nonce length: 16 bytes
- byte `0`: truncated sequence number
- remaining bytes: `0`

Swift currently supports both nonce modes in `ControlPacketCrypto`, though the active Sunshine/Apollo target uses V2.

## Channel IDs

Control/input traffic uses the Moonlight channel IDs from `Limelight-internal.h`:

- `0x00` generic
- `0x01` urgent
- `0x02` keyboard
- `0x03` mouse
- `0x04` pen
- `0x05` touch
- `0x06` utf8
- `0x10...0x1F` gamepad by controller index
- `0x20...0x2F` sensor by controller index

## Implemented Incoming Packet Types

For the current Sunshine/Apollo target, Swift parses these packet types:

- `0x0200` periodic ping (outgoing)
- `0x0302` IDR frame request (outgoing)
- `0x5502` frame FEC status (outgoing Sunshine/Apollo extension)
- `0x0109` termination
- `0x010B` rumble
- `0x010E` HDR mode
- `0x5500` trigger rumble
- `0x5501` set motion event state
- `0x5502` set controller RGB LED
- `0x5503` set adaptive triggers

These values correspond to the encrypted-control-stream packet table in `ControlStream.c`.

Runtime routing:
- rumble, trigger rumble, motion-report, RGB LED, and adaptive-trigger packets are surfaced as typed `SessionEvent.controllerFeedback` effects
- HDR mode changes currently surface as session warnings until the public HDR presentation policy is finalized

## Packet Layouts

### Periodic Ping `0x0200`

Payload fields are little-endian:

Offset | Size | Field
--- | --- | ---
`0` | `2` | payloadLength = `4`
`2` | `4` | timestamp/reserved = `0`
`6` | `2` | zero padding

Notes:
- sent on the generic control channel every 100 ms by the ENet control session
- sent with reliable ENet delivery so ACKs refresh ENet RTT/loss estimates even when most generic-channel traffic is unsequenced or unreliable
- for encrypted control sessions, Swift wraps the same logical packet in the encrypted V2 envelope

### Request IDR Frame `0x0302`

Payload:
- `u16 zero`

Hex example:
```text
02 03 00 00
```

Notes:
- sent on the urgent control channel
- current runtime behavior sends this automatically when video discontinuity is detected and a control channel is available
- for encrypted control sessions, Swift wraps the same logical packet in the encrypted V2 envelope

### Frame FEC Status `0x5502`

Payload fields are big-endian:

Offset | Size | Field
--- | --- | ---
`0` | `4` | `frameIndex`
`4` | `2` | `highestReceivedSequenceNumber`
`6` | `2` | `nextContiguousSequenceNumber`
`8` | `2` | `missingPacketsBeforeHighestReceived`
`10` | `2` | `totalDataPackets`
`12` | `2` | `totalParityPackets`
`14` | `2` | `receivedDataPackets`
`16` | `2` | `receivedParityPackets`
`18` | `1` | `fecPercentage`
`19` | `1` | `multiFecBlockIndex`
`20` | `1` | `multiFecBlockCount`

Notes:
- this is a client-to-host Sunshine/Apollo extension using the same packet type value that Sunshine uses host-to-client for RGB LED updates
- sent best-effort on the generic control channel as an unreliable packet
- Swift currently sends the status when a FEC-described video frame becomes unrecoverable and the runtime is about to request a new keyframe
- for encrypted control sessions, Swift wraps the same logical packet in the encrypted V2 envelope

### Rumble `0x010B`

Payload:
- `u32 reserved`
- `u16 controllerNumber`
- `u16 lowFrequencyMotor`
- `u16 highFrequencyMotor`

Notes:
- the Swift parser ignores the first 4 payload bytes, matching `BbAdvanceBuffer(&bb, 4)` in `ControlStream.c`

Hex example:
```text
0B 01 00 00 00 00 01 00 22 11 44 33
```

### Trigger Rumble `0x5500`

Payload:
- `u16 controllerNumber`
- `u16 leftTriggerMotor`
- `u16 rightTriggerMotor`

Hex example:
```text
00 55 03 00 10 00 20 00
```

### Set Motion Event State `0x5501`

Payload:
- `u16 controllerNumber`
- `u16 reportRateHz`
- `u8 motionType`

Notes:
- `reportRateHz == 0` means stop reporting

Hex example:
```text
01 55 02 00 28 00 02
```

### Set Controller RGB LED `0x5502`

Payload:
- `u16 controllerNumber`
- `u8 r`
- `u8 g`
- `u8 b`

Hex example:
```text
02 55 04 00 10 20 30
```

### HDR Mode `0x010E`

Payload:
- `u8 enabled`
- optional Sunshine/Apollo HDR metadata:
  - `u16 displayPrimary0.x`
  - `u16 displayPrimary0.y`
  - `u16 displayPrimary1.x`
  - `u16 displayPrimary1.y`
  - `u16 displayPrimary2.x`
  - `u16 displayPrimary2.y`
  - `u16 whitePoint.x`
  - `u16 whitePoint.y`
  - `u16 maxDisplayLuminance`
  - `u16 minDisplayLuminance`
  - `u16 maxContentLightLevel`
  - `u16 maxFrameAverageLightLevel`
  - `u16 maxFullFrameLuminance`

Notes:
- Swift parses metadata only when the full 26-byte metadata block is present after the enable byte
- `moonlight-common-c` updates the global HDR state immediately, then dispatches the client callback asynchronously

Hex example:
```text
0E 01 01
64 00 C8 00 2C 01 90 01 F4 01 58 02
BC 02 20 03 E8 03 0A 00 14 00 1E 00 28 00
```

### Adaptive Triggers `0x5503`

Payload:
- `u16 controllerNumber`
- `u8 eventFlags`
- `u8 leftTriggerType`
- `u8 rightTriggerType`
- `u8[10] leftPayload`
- `u8[10] rightPayload`

Flags:
- `0x04` right trigger
- `0x08` left trigger

Notes:
- payload arrays are passed through opaquely
- Swift stores the 10-byte left and right payloads without interpretation

Hex example:
```text
03 55 01 00 0C 01 02
01 02 03 04 05 06 07 08 09 0A
11 12 13 14 15 16 17 18 19 1A
```

### Termination `0x0109`

Two formats are currently recognized.

Extended termination payload:
- `u32 hresult` in big-endian

Short termination payload:
- `u16 reason` in little-endian

Normalization rules implemented in Swift:
- `0x800E9403` -> `frameConversion`
- `0x800E9302` -> `protectedContent`
- `0x80030023` -> `graceful` if at least one frame was seen, else `unexpectedEarly`
- `0x0100` -> `graceful` if at least one frame was seen, else `unexpectedEarly`
- anything else -> raw host code

Hex examples:
```text
09 01 80 0E 93 02
09 01 00 01
```

## Compatibility Notes

- Sunshine and Apollo both use the encrypted control-stream packet IDs this document targets.
- HDR metadata in the HDR control message is treated as a Sunshine-family extension and is parsed when present.
- Apollo-specific higher-level policy behavior still belongs in `docs/APOLLO_COMPATIBILITY.md`; this file is only about packet layout.

## Golden Test Mapping

- `decodesRumblePacket()`
- `decodesTriggerRumblePacket()`
- `decodesMotionAndLedPackets()`
- `decodesHDRPacketWithMetadata()`
- `decodesAdaptiveTriggerPacket()`
- `decodesTerminationAndNormalizesKnownReasons()`
- `shortTerminationBeforeFramesMapsToUnexpectedEarly()`
- `controlServiceReceivesAndSendsPackets()`
- `roundTripsEncryptedControlPacketV2()`
- `controlServiceDecodesEncryptedIncomingPacket()`
- `serviceSendsEncryptedPacketOnUrgentChannel()`
