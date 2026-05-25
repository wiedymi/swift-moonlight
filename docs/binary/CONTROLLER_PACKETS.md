# Controller Packets

Status:
- implemented for arrival, state, disconnect, battery, motion, and controller-touch packets

Primary references:
- `refs/moonlight-common-c/src/Input.h`
- `refs/moonlight-common-c/src/InputStream.c`
- `refs/moonlight-common-c/src/Limelight.h`

## Controller Arrival

Struct:
- `SS_CONTROLLER_ARRIVAL_PACKET`

Magic:
- `0x55000004`

Layout:
- `size`: big-endian `uint32`
- `magic`: little-endian `uint32`
- `controllerNumber`: `uint8`
- `type`: `uint8`
- `capabilities`: little-endian `uint16`
- `supportedButtonFlags`: little-endian `uint32`

Current encoder behavior:
- emits this packet for Sunshine/Apollo-compatible hosts
- emits an `NV_MULTI_CONTROLLER_PACKET` fallback immediately after arrival
- `supportedButtonFlags` is derived from the semantic `ControllerButtons` option set
- capabilities are derived from the semantic descriptor booleans using `LI_CCAP_*` bits
- analog triggers are always advertised

Hex example:
- `0000000C040000550101030000F40000`

## Multi-Controller Packet

Struct:
- `NV_MULTI_CONTROLLER_PACKET`

Magic:
- `0x0000000C`

Layout:
- `size`: big-endian `uint32`
- `magic`: little-endian `uint32`
- `headerB`: little-endian `int16`, constant `0x001A`
- `controllerNumber`: little-endian `int16`
- `activeGamepadMask`: little-endian `int16`
- `midB`: little-endian `int16`, constant `0x0014`
- `buttonFlags`: little-endian low 16 bits
- `leftTrigger`: `uint8`
- `rightTrigger`: `uint8`
- `leftStickX`: little-endian `int16`
- `leftStickY`: little-endian `int16`
- `rightStickX`: little-endian `int16`
- `rightStickY`: little-endian `int16`
- `tailA`: little-endian `int16`, constant `0x009C`
- `buttonFlags2`: little-endian high 16 bits
- `tailB`: little-endian `int16`, constant `0x0055`

Current encoder behavior:
- used for controller state
- used as the fallback packet after controller arrival
- used for controller disconnect with zeroed state and cleared active mask

Hex example for arrival fallback:
- `0000001E0C0000001A000100020014000000000000000000000000009C0000005500`

Hex example for controller state:
- `0000001E0C0000001A0001000200140000553FFFFF3F01C00000FF7F9C0000005500`

Current button mapping:
- low 16 bits: d-pad, start, back, stick clicks, shoulders, guide, A/B/X/Y
- high 16 bits: paddles, touchpad, misc/share/capture

## Additional Sunshine-Compatible Extension Packets

Implemented layouts:
- `SS_CONTROLLER_BATTERY_PACKET`
- `SS_CONTROLLER_MOTION_PACKET`
- `SS_CONTROLLER_TOUCH_PACKET`

Golden tests currently cover:
- arrival
- state
- battery
- motion
- controller touchpad
