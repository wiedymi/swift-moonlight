# Channel Establishment Protocol

Status:
- implemented as a transport-agnostic planning and establishment layer
- live UDP media establishment is implemented for the current Sunshine ping-path
- ENet-backed control/input establishment is implemented for the current Sunshine/Apollo control path
- TCP fallback and historical non-ENet control variants are still not implemented here

References:
- `refs/moonlight-common-c/src/Connection.c`
- `refs/moonlight-common-c/src/RtspConnection.c`
- `refs/sunshine/src/stream.cpp`
- `refs/apollo/src/stream.cpp`

## Goal

Turn RTSP-negotiated port and extension data into a concrete channel set:
- control
- input
- video
- audio

## Implemented Swift Types

```swift
public enum ChannelKind: Sendable {
    case control
    case input
    case video
    case audio
}

public struct ChannelDescriptor: Sendable {
    public var kind: ChannelKind
    public var port: UInt16
    public var metadata: [String: String]
}

public struct EstablishedChannel: Sendable {
    public var descriptor: ChannelDescriptor
    public var isConnected: Bool
}
```

## Current Planning Rules

- control uses the negotiated RTSP control stream port
- input is currently modeled as a logical sibling of control and reuses the control port
- video uses the negotiated video stream port
- audio uses the negotiated audio stream port
- input-only sessions establish only:
  - control
  - input

## Current Metadata Mapping

- control:
  - `connectData` from `X-SS-Connect-Data` when present
- video:
  - `pingPayload` from `X-SS-Ping-Payload` when present
- audio:
  - `pingPayload` from `X-SS-Ping-Payload` when present

Current runtime handling:
- `UDPChannelTransport` sends the one-shot establishment probe for video/audio channels when a `pingPayload` is present
- `ChannelSocketFactory` also wires periodic media keepalives on the live video/audio sockets using the same Sunshine ping packet format
- the ENet control session sends a generic `0x0200` periodic ping every 100 ms using reliable delivery, matching Moonlight's RTT-refresh behavior
- ENet-backed control transports expose `ControlTransportMetricsReporting` snapshots for control RTT, RTT variance, packet-loss ratio, and packet-loss variance

## Current Services

- `ChannelPlanBuilder`
- `ChannelEstablishmentService`
- `ChannelProbeBuilder`
- `UDPChannelTransport`
- `ENetControlSession`
- `ENetControlChannelTransport`
- `SessionBootstrap`

`SessionBootstrap` composes:
1. launch service
2. RTSP negotiation service
3. channel establishment service

## Test Coverage

- full-session channel plan
- input-only channel plan
- establishment order
- Sunshine ping probe encoding
- UDP video probe send on a live loopback socket
- bootstrap path through `MoonlightClient.openSession()`
