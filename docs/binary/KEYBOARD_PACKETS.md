# Keyboard Packets

Status:
- partially implemented with real Moonlight-compatible packet headers and field endianness

Primary references:
- `refs/moonlight-common-c/src/Input.h`
- `refs/moonlight-common-c/src/InputStream.c`

## Key Event Packet

Struct:
- `NV_KEYBOARD_PACKET`

Magics:
- key down: `0x00000003`
- key up: `0x00000004`

Layout:
- `size`: big-endian `uint32`
- `magic`: little-endian `uint32`
- `flags`: `uint8`
- `keyCode`: little-endian `int16`
- `modifiers`: `uint8`
- `zero2`: little-endian `int16`

Current encoder behavior:
- `flags = 0`
- key codes are encoded as 16-bit Win32 virtual key values
- extended keys such as right-side modifiers use their distinct virtual key codes
- modifiers map directly into the bitmask expected by the protocol

Modifier bits:
- shift: `0x01`
- control: `0x02`
- alt: `0x04`
- meta: `0x08`

Hex example:
- `0000000A03000000002000000000`

Meaning:
- size = `10`
- magic = key down
- flags = `0`
- keyCode = `0x20` (space)
- modifiers = `0`
- zero2 = `0`

## UTF-8 Text Packet

Struct:
- `NV_UNICODE_PACKET`

Magic:
- `0x00000017`

Layout:
- `size`: big-endian `uint32`
- `magic`: little-endian `uint32`
- `text`: raw UTF-8 bytes

Current encoder behavior:
- accepts UTF-8 payloads up to 32 bytes

Hex example:
- `000000051700000041`
