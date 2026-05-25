# Mouse Packets

Status:
- partially implemented with real Moonlight-compatible packet headers and field endianness

Primary references:
- `refs/moonlight-common-c/src/Input.h`
- `refs/moonlight-common-c/src/InputStream.c`

## Shared Header

All mouse packets begin with `NV_INPUT_HEADER`:
- bytes `0..3`: packet size excluding the size field, big-endian `uint32`
- bytes `4..7`: packet magic, little-endian `uint32`

## Relative Mouse Move

Struct:
- `NV_REL_MOUSE_MOVE_PACKET`

Magic:
- `0x00000007` for Gen 5 style hosts

Layout:
- header
- `deltaX`: big-endian `int16`
- `deltaY`: big-endian `int16`

Hex example:
- `00000008070000000008FFFE`

Meaning:
- size = `8`
- magic = `0x07`
- `deltaX = 8`
- `deltaY = -2`

Runtime send behavior:
- relative motion is batched before transport send
- multiple pending relative moves accumulate into one packet carrying the latest summed delta
- accumulated deltas that exceed signed 16-bit packet fields are split across multiple relative-move packets instead of clamped

## Absolute Mouse Move

Struct:
- `NV_ABS_MOUSE_MOVE_PACKET`

Magic:
- `0x00000005`

Layout:
- header
- `x`: big-endian `int16`
- `y`: big-endian `int16`
- `unused`: big-endian `int16`
- `width`: big-endian `int16`
- `height`: big-endian `int16`

Current encoder behavior:
- semantic unit coordinates are mapped into a reference plane
- runtime derives the reference plane from `InputEncodingContext.streamViewport`, normally the negotiated video width/height
- host compatibility profile is carried in `InputEncodingContext` so Sunshine/Apollo input behavior stays outside app code
- default reference width/height are `Int16.max` only as a fallback when no viewport is known
- encoded `x`/`y` are clamped into `0...reference`
- encoded `width`/`height` are sent as `reference - 1`, matching Moonlight's host-side edge-reach workaround
- Sunshine/Apollo host-side touch-port transforms happen after packet decode; app/UI code should map absolute pointer events against the presented stream surface, not apply host-specific offsets itself
- `HostInputCoordinateOracle` covers the observed host-side edge, letterbox, and Sunshine-vs-Apollo logical-port differences in headless tests

Runtime send behavior:
- absolute motion is batched before transport send by default
- only the newest pending absolute position is kept
- queued absolute motion is flushed before later button packets so click order remains correct
- latency-sensitive integrations should start with the default 1 ms coalesced mouse delivery; immediate delivery is available through `InputSenderConfiguration` for diagnostics or sparse pointer sources and changes send timing, not packet layout

Hex example:
- `0000000C050000003FFF1FFF00007FFE7FFE`

## Mouse Button

Struct:
- `NV_MOUSE_BUTTON_PACKET`

Magics:
- press: `0x00000008`
- release: `0x00000009`

Layout:
- header
- `button`: `uint8`

Button codes:
- left: `0x01`
- middle: `0x02`
- right: `0x03`
- x1: `0x04`
- x2: `0x05`

Hex example:
- `000000050800000001`

## Vertical Scroll

Struct:
- `NV_SCROLL_PACKET`

Magic:
- `0x0000000A` for Gen 5 style hosts

Layout:
- header
- `scrollAmt1`: big-endian `int16`
- `scrollAmt2`: big-endian `int16`
- `zero3`: `0`

Current encoder behavior:
- high-resolution scroll path is used directly
- `scrollAmt1` and `scrollAmt2` are both set to the provided delta

Hex example:
- `0000000A0A000000007800780000`

## Horizontal Scroll

Struct:
- `SS_HSCROLL_PACKET`

Magic:
- `0x55000001`

Layout:
- header
- `scrollAmount`: big-endian `int16`

Note:
- this is a Sunshine-compatible extension path
