# Swift ENet client contract

Scope: one client peer for Sunshine and Apollo. No C module, server API,
compression, custom checksum, or broadcast API. ENet control and input share
the same socket. Media sockets are separate.

Behavior references: ENet 1.3.18 bundled at parent commit 3ae6b69; the MIT
Moonlight fork `cgutman/enet` at c7353c059373f8d3fc83d451f8f1a477be3dc94e.
The fork's retry and RTT behavior is the target. This document describes
behavior; the Swift code is written independently.

## Layout

All ENet numeric fields use network byte order. The four-byte connect ID is
opaque and echoed unchanged. Application control fields retain their existing
little-endian format and encryption, outside ENet.

A datagram starts with a 16-bit peer field: peer ID in bits 0...11, session ID
in bits 12...13, compressed flag in bit 14, sent-time flag in bit 15. The
optional 16-bit sent time is milliseconds modulo 65536. The client peer ID is
zero; an initial connect uses destination peer ID 4095 with header session bits
zero. Commands follow without
padding, at most 32 per outgoing datagram.

Every command starts with a byte of command/flags, channel byte, and 16-bit
reliable sequence. Command numbers occupy bits 0...3. Bit 7 requests an ACK;
bit 6 marks unsequenced traffic. The management channel is 255.

| Command | Number | Bytes including command header, excluding payload |
| --- | --- | --- |
| ACK | 1 | 8: acknowledged sequence, echoed sent time |
| Connect | 2 | 48 |
| Verify connect | 3 | 44 |
| Disconnect | 4 | 8: reason |
| Ping | 5 | 4 |
| Reliable payload | 6 | 6: payload length |
| Unreliable payload | 7 | 8: unreliable sequence, payload length |
| Reliable fragment | 8 | 24 |
| Unsequenced payload | 9 | 8: group, payload length |
| Bandwidth limit | 10 | 12: incoming/outgoing bytes per second |
| Throttle configuration | 11 | 16: interval, increase, decrease |
| Unreliable fragment | 12 | 24 |

Connect and verify contain outgoing peer ID (16-bit), incoming/outgoing session
IDs (bytes), then 32-bit MTU, window, channel count, incoming/outgoing bandwidth,
throttle interval/increase/decrease, and opaque connect ID. Connect also contains
32-bit application connect data. Initial session IDs are 255. The client asks
for 48 channels, MTU 900, window 65536, unlimited bandwidth, and throttle values
5000/2/2. Verify must echo the connect ID and throttle values. A smaller channel
count is accepted; application channels outside it map to channel zero.

Fragments contain a 16-bit start sequence and payload length, followed by 32-bit
fragment count, fragment number, total message length, and byte offset. Reliable
fragments each consume a reliable sequence; unreliable fragments share one
unreliable start sequence and a reliable dependency sequence.

## Delivery and limits

Reliable sequences wrap at 16 bits. A reliable message is delivered once, in
order per channel. Unreliable messages depend on a reliable sequence and discard
older unreliable sequences. A reliable command resets the outgoing unreliable
sequence. Unreliable sequence exhaustion sends the next payload reliably.
Large application messages use reliable fragments, as in the existing client.
Receive supports reliable/unreliable fragments and unsequenced duplicate removal.

Retry deadlines use monotonic milliseconds. Initial RTT is 500 ms. The retry
base is RTT plus min(RTT, 4 * max(1, RTT variance)), capped at one fifth of the
10-second peer timeout. Retry delay grows linearly to twice this base. RTT
updates use rounded 1/8 mean and 1/4 variance steps. Waiting for UDP data must
not prevent retry deadlines. Moonlight application ping remains reliable every
100 ms; ENet ping is separate.

The implementation bounds payload size at 1 MiB, queued bytes at 4 MiB,
fragment count at 4096, receive entries at 4096 per channel, and total retained
or reserved receive entries at 8192. A first fragment reserves its full declared
message size and fragment count before a final-sized buffer is allocated.
Later fragments write into that buffer after range and overlap validation.
Outbound commands are also capped at 8192. Reliable flight
uses the negotiated byte window and a conservative sequence window. Compressed,
unknown, or truncated datagrams are rejected before any command changes state.
No ACK is sent for payloads that cannot be retained. An incomplete acknowledged
reliable message cannot be silently expired; the connection fails instead.
This is a deliberate smaller memory limit than general ENet's 32 MiB default.

The socket queues at most 256 datagrams. One readiness notification wakes the
connection for all packets already available. ACKs share a datagram when possible;
the ACK queue flushes at 32 commands or at the end of the read group. No wait is
added to collect more packets. Retry and application ping timers remain active.

The connection and public adapter actors share the socket's native serial
executor. Socket callbacks enter the actor directly on macOS 15, iOS/tvOS 18,
and visionOS 2 or newer. Older supported systems schedule an actor task instead,
because their runtime cannot check isolation from a native callback. One reusable
native timer replaces per-deadline sleeping tasks. ACK processing can move its
deadline later to prevent a wake for a command that no longer needs a retry.
All mutable socket buffers are inside `OSAllocatedUnfairLock`; socket `Sendable`
conformance is compiler checked. The package explicitly uses Swift 6 language
mode, which requires complete concurrency checks.

The 32-bit encryption sequence does not wrap under one key. Legacy control
crypto behavior is unchanged; Sunshine/Apollo use the existing v2 context. Retries reuse the same encrypted
bytes. The public session constructor and socket factory become async so connect
does not block an executor. Higher-level client/session APIs remain unchanged.

## Acceptance

Golden packet bytes; connect validation; lost and duplicate ACKs; per-channel
ordering; sequence/time wrap; fragmentation; queue limits; malformed packets;
IPv4/IPv6 loopback; cancellation/close; RTT/loss snapshots; C reference interop
and release performance comparison. Live VVMoon/host checks are a later review.

## Socket address choice

For a hostname with both address families, IPv4 is tried first to preserve the
previous library path. Explicit IPv6 addresses and IPv6-only names use IPv6.
UDP socket setup failures try the next address. There is no parallel connection
race or automatic family switch after a handshake timeout. The fixed remote
endpoint also preserves the previous client's sender-address restriction.

## Package owner

The engine and native UDP client now live in the pinned
[SwiftENet package](https://github.com/wiedymi/swift-enet). The wire behavior above
remains the reference for Moonlight integration. The public SwiftENet sender
rejects invalid channels and returns channel IDs with received packets. Only the
Moonlight adapter applies channel-zero fallback. Encryption, startup packets,
and the reliable 100 ms application ping remain in SwiftMoonlight. Reliable
sequence ranges have one owner; conflicting messages or fragments are rejected.
