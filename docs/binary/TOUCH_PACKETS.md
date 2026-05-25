# Touch Packets

Status:
- implemented for Sunshine-compatible touch and pen packets

Primary references:
- `refs/moonlight-common-c/src/Input.h`
- `refs/moonlight-common-c/src/Limelight.h`

## Touch Packet

Struct:
- `SS_TOUCH_PACKET`

Magic:
- `0x55000002`

Layout:
- `size`: big-endian `uint32`
- `magic`: little-endian `uint32`
- `eventType`: `uint8`
- reserved byte
- `rotation`: little-endian `uint16`
- `pointerId`: little-endian `uint32`
- `x`: netfloat, little-endian IEEE 754 float in `0...1`
- `y`: netfloat, little-endian IEEE 754 float in `0...1`
- `pressureOrDistance`: netfloat
- `contactAreaMajor`: netfloat
- `contactAreaMinor`: netfloat

Current encoder behavior:
- `TouchPhase.hovering` -> `LI_TOUCH_EVENT_HOVER` (`0x00`)
- `TouchPhase.began` -> `LI_TOUCH_EVENT_DOWN` (`0x01`)
- `TouchPhase.moved` -> `LI_TOUCH_EVENT_MOVE` (`0x03`)
- `TouchPhase.ended` -> `LI_TOUCH_EVENT_UP` (`0x02`)
- `TouchPhase.cancelled` -> `LI_TOUCH_EVENT_CANCEL` (`0x04`)
- `TouchPhase.hoverEnded` -> `LI_TOUCH_EVENT_HOVER_LEAVE` (`0x06`)
- `TouchPhase.cancelledAll` -> `LI_TOUCH_EVENT_CANCEL_ALL` (`0x07`)
- `x`, `y`, pressure/distance, and contact ellipse fields are clamped into `0...1` before encoding
- rotation, pressure, and contact ellipse are propagated from the semantic touch event
- Sunshine and Apollo receive the same normalized client-surface packet bytes; their touch-port coordinate differences are host-side transforms after packet decode

Hex example:
- `00000020020000550100FFFF070000000000003F0000803E000000000000000000000000`

Meaning:
- size = `32`
- magic = `0x55000002`
- event type = down
- pointer id = `7`
- `x = 0.5`
- `y = 0.25`

## Pen Packet

Struct:
- `SS_PEN_PACKET`

Magic:
- `0x55000003`

Layout:
- `size`: big-endian `uint32`
- `magic`: little-endian `uint32`
- `eventType`: `uint8`
- `toolType`: `uint8`
- `penButtons`: `uint8`
- reserved byte
- `x`: netfloat
- `y`: netfloat
- `pressureOrDistance`: netfloat
- `rotation`: little-endian `uint16`
- `tilt`: `uint8`
- reserved byte
- `contactAreaMajor`: netfloat
- `contactAreaMinor`: netfloat

Current encoder behavior:
- `x`, `y`, pressure/distance, and contact ellipse fields are clamped into `0...1` before encoding
- Sunshine and Apollo receive the same normalized client-surface packet bytes; their touch-port coordinate differences are host-side transforms after packet decode

Hex example:
- `0000002003000055030101000000803E0000403F0000003F5A000C00CDCC4C3ECDCCCC3D`
