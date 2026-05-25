# RTSP Messages

Status:
- implemented for message parsing, serialization, request planning, and setup-response field extraction
- live RTSP transaction transport is implemented through `NetworkRTSPTransport`
- encrypted `rtspenc://` RTSP framing is implemented using AES-GCM and the launch `rikey`

Primary references:
- `refs/moonlight-common-c/src/Rtsp.h`
- `refs/moonlight-common-c/src/RtspConnection.c`
- `refs/sunshine/src/rtsp.cpp`
- `refs/apollo/src/rtsp.cpp`

## Message Framing

Current implementation assumes standard RTSP text framing:
- start line
- zero or more header lines
- `\r\n\r\n` terminator
- optional body bytes after the header terminator

Encrypted framing:
- live Sunshine and Apollo launches may return `sessionUrl0` with scheme `rtspenc://`
- in that mode, each RTSP packet is:
  - 4-byte big-endian `typeAndLength` with the high bit set and the plaintext length in the low bits
  - 4-byte big-endian sequence number
  - 16-byte AES-GCM tag
  - ciphertext with the same length as the plaintext RTSP message
- the AES-GCM key is the 16-byte `rikey` supplied in `/launch`
- nonce construction matches the reference clients and host implementations:
  - bytes `0...3` are the sequence number in little-endian order
  - bytes `10...11` are `CR` for client-originated packets and `HR` for host-originated packets

Implemented Swift types:
- `RTSPRequest`
- `RTSPResponse`
- `RTSPMessage`
- `RTSPMessageParser`

## Request Start Line

Layout:
- `<METHOD> <TARGET> RTSP/1.0`

Implemented methods:
- `DESCRIBE`
- `SETUP`
- `ANNOUNCE`
- `PLAY`

## Response Start Line

Layout:
- `RTSP/1.0 <STATUS_CODE> <STATUS_TEXT>`

Current parser behavior:
- extracts protocol version
- extracts numeric status code
- preserves the remaining text as the status string

## Header Parsing

Current parser behavior:
- splits headers on the first `:`
- preserves original header order
- supports case-insensitive lookup by name

Implemented setup-response extraction:
- `Session`
  - trims any `;timeout=...` suffix and keeps only the session ID token
- `Transport`
  - extracts the first `server_port` value
- `X-SS-Ping-Payload`
- `X-SS-Connect-Data`
  - supports decimal or `0x` hex text

## Request Planning

Implemented builder:
- `RTSPRequestPlanBuilder`

Current modern plan:
1. `DESCRIBE <session-url>`
2. `SETUP streamid=audio/0/0`
3. `SETUP streamid=video/0/0`
4. `SETUP streamid=control/13/0`
5. `ANNOUNCE streamid=control/13/0`
6. `PLAY /`

Legacy play fallback:
1. `PLAY streamid=video`
2. `PLAY streamid=audio`

## Current Limitations

- no SDP parser yet
- RTSP transaction transport is currently TCP-only
- channel establishment after successful RTSP setup is implemented separately in `ChannelEstablishmentService`

## Golden Test Mapping

- `RTSPTests.parsesRTSPResponseAndHeaders`
- `RTSPTests.serializesRTSPDescribeRequest`
- `RTSPTests.extractsSessionInfoFromSetupResponse`
- `RTSPTests.buildsUnifiedRTSPSessionPlan`
- `RTSPTests.buildsLegacyRTSPPlayPlan`
